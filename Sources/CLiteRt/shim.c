#include "CLiteRt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define NOGDI
#include <windows.h>
static SRWLOCK g_env_lock = SRWLOCK_INIT;
#define ENV_LOCK() AcquireSRWLockExclusive(&g_env_lock)
#define ENV_UNLOCK() ReleaseSRWLockExclusive(&g_env_lock)
typedef SRWLOCK dal_mutex;
static void mutex_init(dal_mutex* m) { InitializeSRWLock(m); }
static void mutex_lock(dal_mutex* m) { AcquireSRWLockExclusive(m); }
static void mutex_unlock(dal_mutex* m) { ReleaseSRWLockExclusive(m); }
static void mutex_destroy(dal_mutex* m) { (void)m; }
#else
#include <pthread.h>
static pthread_mutex_t g_env_lock = PTHREAD_MUTEX_INITIALIZER;
#define ENV_LOCK() pthread_mutex_lock(&g_env_lock)
#define ENV_UNLOCK() pthread_mutex_unlock(&g_env_lock)
typedef pthread_mutex_t dal_mutex;
static void mutex_init(dal_mutex* m) { pthread_mutex_init(m, NULL); }
static void mutex_lock(dal_mutex* m) { pthread_mutex_lock(m); }
static void mutex_unlock(dal_mutex* m) { pthread_mutex_unlock(m); }
static void mutex_destroy(dal_mutex* m) { pthread_mutex_destroy(m); }
#endif

// One LiteRT environment per process, created on first use and kept for the
// life of the process. Creating one runs the accelerator registry, which tries
// to load the GPU and NPU accelerator libraries and logs every step to stderr
// at INFO and WARNING (eight lines on a machine without them). The vendored
// runtime exports no logger control, so the only way to stop that repeating
// for every session is to not repeat the environment. A failed creation is not
// cached: the next session tries again.
static LiteRtEnvironment g_env = NULL;

static LiteRtEnvironment shared_environment(void) {
  ENV_LOCK();
  if (!g_env && LiteRtCreateEnvironment(0, NULL, &g_env) != kLiteRtStatusOk) g_env = NULL;
  LiteRtEnvironment env = g_env;
  ENV_UNLOCK();
  return env;
}

// A compiled model, shared by the sessions that run different signatures of
// the same file.
//
// A .tflite can carry several signatures (schemer's encoder has one per
// sequence window, over one copy of the weights), and a session runs exactly
// one of them. Compiling the file once per session would repack the weights
// once per signature: three windows would cost three times the memory for one
// file's worth of weights. So a session that names a signature joins a
// compiled model of the same path and accelerator whose sessions run other
// signatures, reference-counted, and takes its run lock, because a compiled
// model does not promise that two signatures can run on it at once.
//
// Everything else gets a compiled model of its own, as before sharing
// existed: a session that names no signature (every single-signature model),
// and a second session of a signature already in use. The second case is a
// pool, several sessions of one graph so runs can overlap (Clear keeps one per
// worker), and joining would serialize it behind the run lock; on Windows it
// also crashed. Bytes have no identity to key on, so they are never shared.
typedef struct DalLrtCompiled {
  LiteRtModel model;
  LiteRtOptions options;
  LiteRtCompiledModel compiled;
  // Owned copy of the model bytes when created from a buffer. LiteRT's
  // LiteRtCreateModelFromBuffer is zero-copy ("the caller must ensure the
  // buffer remains valid for the lifetime of the model"), so we must keep the
  // bytes alive for as long as the model/compiled model reads them.
  void* model_data;
  char* key;     // "<accelerator>:<path>", NULL when never shared
  int refs;      // guarded by g_env_lock
  char** signatures;  // the signature each session on this model runs
  int num_signatures; // guarded by g_env_lock
  dal_mutex run_lock;
  struct DalLrtCompiled* next;
} DalLrtCompiled;

static DalLrtCompiled* g_compiled = NULL;  // guarded by g_env_lock

// One signature of a compiled model with its fixed-shape input/output host
// buffers, created once and reused: each run writes inputs, invokes, and
// copies outputs out.

struct DalLrtSession {
  LiteRtEnvironment env;  // the process-wide one above, not owned
  DalLrtCompiled* shared;
  char* signature_name;   // as requested; NULL for the first signature
  LiteRtParamIndex signature;

  int num_inputs;
  int num_outputs;
  char** input_names;
  char** output_names;

  LiteRtTensorBuffer* input_buffers;
  LiteRtTensorBuffer* output_buffers;

  // Output metadata (fixed shapes), plus an owned copy of the last output data.
  int* out_element;
  int* out_rank;
  int32_t* out_dims;   // num_outputs * LITERT_TENSOR_MAX_RANK
  size_t* out_bytes;
  void** out_copy;
};

static void set_err(char* errbuf, int len, const char* msg) {
  if (errbuf && len > 0) {
    size_t n = strlen(msg);
    if (n > (size_t)(len - 1)) n = (size_t)(len - 1);
    memcpy(errbuf, msg, n);
    errbuf[n] = '\0';
  }
}

static size_t element_size(LiteRtElementType t) {
  switch (t) {
    case kLiteRtElementTypeInt64: return 8;
    default: return 4;  // float32, int32
  }
}

static size_t layout_bytes(const LiteRtRankedTensorType* type) {
  size_t n = 1;
  for (unsigned int i = 0; i < type->layout.rank; i++) {
    int32_t d = type->layout.dimensions[i];
    n *= (d > 0 ? (size_t)d : 1);
  }
  return n * element_size(type->element_type);
}

static void destroy_compiled(DalLrtCompiled* c) {
  if (!c) return;
  if (c->compiled) LiteRtDestroyCompiledModel(c->compiled);
  if (c->options) LiteRtDestroyOptions(c->options);
  if (c->model) LiteRtDestroyModel(c->model);
  // Freed only after the model that references it is destroyed.
  free(c->model_data);
  free(c->key);
  for (int i = 0; i < c->num_signatures; i++) free(c->signatures[i]);
  free(c->signatures);
  mutex_destroy(&c->run_lock);
  free(c);
}

static char* copy_string(const char* s);

static int runs_signature(const DalLrtCompiled* c, const char* signature) {
  for (int i = 0; i < c->num_signatures; i++)
    if (strcmp(c->signatures[i], signature) == 0) return 1;
  return 0;
}

// Record that a session runs `signature` on `c`. Called with g_env_lock held.
static int add_signature(DalLrtCompiled* c, const char* signature) {
  char** grown = (char**)realloc(c->signatures, (size_t)(c->num_signatures + 1) * sizeof(char*));
  if (!grown) return 0;
  c->signatures = grown;
  c->signatures[c->num_signatures] = copy_string(signature);
  if (!c->signatures[c->num_signatures]) return 0;
  c->num_signatures++;
  return 1;
}

static void release_compiled(DalLrtCompiled* c, const char* signature) {
  if (!c) return;
  ENV_LOCK();
  if (signature) {
    for (int i = 0; i < c->num_signatures; i++) {
      if (strcmp(c->signatures[i], signature) == 0) {
        free(c->signatures[i]);
        c->signatures[i] = c->signatures[--c->num_signatures];
        break;
      }
    }
  }
  int last = --c->refs == 0;
  if (last) {
    for (DalLrtCompiled** p = &g_compiled; *p; p = &(*p)->next) {
      if (*p == c) { *p = c->next; break; }
    }
  }
  ENV_UNLOCK();
  if (last) destroy_compiled(c);
}

// Load and compile, or join a compiled model of the same file whose sessions
// run other signatures (see DalLrtCompiled for when a model is shared).
// Holding g_env_lock across the compile serializes model loads, which is what
// stops two sessions racing to compile the same file.
static DalLrtCompiled* acquire_compiled(LiteRtEnvironment env, const char* path,
                                        const void* data, size_t data_len,
                                        int accelerator, const char* signature,
                                        char* errbuf, int errbuf_len) {
  char* key = NULL;
  if (path && signature) {
    size_t n = strlen(path) + 16;
    key = (char*)malloc(n);
    if (!key) { set_err(errbuf, errbuf_len, "out of memory"); return NULL; }
    snprintf(key, n, "%d:%s", accelerator, path);
  }
  ENV_LOCK();
  if (key) {
    for (DalLrtCompiled* c = g_compiled; c; c = c->next) {
      if (c->key && strcmp(c->key, key) == 0 && !runs_signature(c, signature)) {
        if (!add_signature(c, signature)) {
          ENV_UNLOCK(); free(key); set_err(errbuf, errbuf_len, "out of memory"); return NULL;
        }
        c->refs++;
        ENV_UNLOCK();
        free(key);
        return c;
      }
    }
  }
  DalLrtCompiled* c = (DalLrtCompiled*)calloc(1, sizeof(DalLrtCompiled));
  if (!c) { ENV_UNLOCK(); free(key); set_err(errbuf, errbuf_len, "out of memory"); return NULL; }
  mutex_init(&c->run_lock);
  c->key = key;
  c->refs = 1;
  if (path) {
    if (LiteRtCreateModelFromFile(env, path, &c->model) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "LiteRtCreateModelFromFile failed"); goto fail;
    }
  } else if (data && data_len > 0) {
    // Copy the bytes into a buffer we own: LiteRtCreateModelFromBuffer keeps a
    // zero-copy reference, and the caller's buffer (e.g. a Swift [UInt8] or a
    // JNI byte[]) is freed as soon as create returns, which would leave the
    // model's flatbuffer dangling and crash at run.
    c->model_data = malloc(data_len);
    if (!c->model_data) { set_err(errbuf, errbuf_len, "out of memory"); goto fail; }
    memcpy(c->model_data, data, data_len);
    if (LiteRtCreateModelFromBuffer(env, c->model_data, data_len, &c->model) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "LiteRtCreateModelFromBuffer failed"); goto fail;
    }
  } else {
    set_err(errbuf, errbuf_len, "no model path or bytes"); goto fail;
  }
  // Compile for the requested accelerator(s), but fall back to CPU if that
  // fails, so a preferred GPU/NPU (used automatically when its accelerator
  // library is bundled) never breaks model load on a device that lacks it or
  // whose driver rejects the model. Ops the accelerator cannot run are already
  // partitioned onto CPU by LiteRT; this only guards a hard compile failure.
  LiteRtHwAcceleratorSet accel =
      accelerator ? (LiteRtHwAcceleratorSet)accelerator : kLiteRtHwAcceleratorCpu;
  LiteRtStatus compiled_status = kLiteRtStatusErrorRuntimeFailure;
  for (int attempt = 0; attempt < 2; attempt++) {
    if (LiteRtCreateOptions(&c->options) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "LiteRtCreateOptions failed"); goto fail;
    }
    LiteRtSetOptionsHardwareAccelerators(c->options, accel);
    compiled_status = LiteRtCreateCompiledModel(env, c->model, c->options, &c->compiled);
    if (compiled_status == kLiteRtStatusOk) break;
    // Failed: drop this attempt's options and, if we asked for more than CPU,
    // retry CPU-only once.
    LiteRtDestroyOptions(c->options); c->options = NULL;
    if (accel == kLiteRtHwAcceleratorCpu) break;
    accel = kLiteRtHwAcceleratorCpu;
  }
  if (compiled_status != kLiteRtStatusOk) {
    set_err(errbuf, errbuf_len, "LiteRtCreateCompiledModel failed"); goto fail;
  }
  if (key) {
    if (!add_signature(c, signature)) { set_err(errbuf, errbuf_len, "out of memory"); goto fail; }
    c->next = g_compiled; g_compiled = c;
  }
  ENV_UNLOCK();
  return c;

fail:
  ENV_UNLOCK();
  destroy_compiled(c);
  return NULL;
}

void dal_lrt_free(DalLrtSession* s) {
  if (!s) return;
  if (s->input_buffers) {
    for (int i = 0; i < s->num_inputs; i++)
      if (s->input_buffers[i]) LiteRtDestroyTensorBuffer(s->input_buffers[i]);
    free(s->input_buffers);
  }
  if (s->output_buffers) {
    for (int i = 0; i < s->num_outputs; i++)
      if (s->output_buffers[i]) LiteRtDestroyTensorBuffer(s->output_buffers[i]);
    free(s->output_buffers);
  }
  if (s->input_names) {
    for (int i = 0; i < s->num_inputs; i++) free(s->input_names[i]);
    free(s->input_names);
  }
  if (s->output_names) {
    for (int i = 0; i < s->num_outputs; i++) free(s->output_names[i]);
    free(s->output_names);
  }
  if (s->out_copy) {
    for (int i = 0; i < s->num_outputs; i++) free(s->out_copy[i]);
    free(s->out_copy);
  }
  free(s->out_element);
  free(s->out_rank);
  free(s->out_dims);
  free(s->out_bytes);
  release_compiled(s->shared, s->signature_name);
  free(s->signature_name);
  free(s);
}

static char* copy_string(const char* s) {
  size_t n = strlen(s) + 1;
  char* out = (char*)malloc(n);
  if (out) memcpy(out, s, n);
  return out;
}

DalLrtSession* dal_lrt_create(const char* path, const void* data, size_t data_len,
                              int accelerator, const char* signature,
                              char* errbuf, int errbuf_len) {
  DalLrtSession* s = (DalLrtSession*)calloc(1, sizeof(DalLrtSession));
  if (!s) { set_err(errbuf, errbuf_len, "out of memory"); return NULL; }

  s->env = shared_environment();
  if (!s->env) {
    set_err(errbuf, errbuf_len, "LiteRtCreateEnvironment failed"); goto fail;
  }
  if (signature && *signature) {
    s->signature_name = copy_string(signature);
    if (!s->signature_name) { set_err(errbuf, errbuf_len, "out of memory"); goto fail; }
  }
  s->shared = acquire_compiled(s->env, path, data, data_len, accelerator, s->signature_name,
                               errbuf, errbuf_len);
  if (!s->shared) goto fail;
  LiteRtModel model = s->shared->model;
  LiteRtCompiledModel compiled = s->shared->compiled;

  // The signature this session runs: the named one, or the first. Every
  // name, type and buffer below is read through it, never through subgraph
  // 0, because a signature lists its tensors in its own order (sorted by
  // name for litert-torch exports), which need not be the subgraph's.
  LiteRtParamIndex num_sigs = 0;
  if (LiteRtGetNumModelSignatures(model, &num_sigs) != kLiteRtStatusOk || num_sigs == 0) {
    set_err(errbuf, errbuf_len, "the model declares no signature"); goto fail;
  }
  LiteRtSignature sig = NULL;
  s->signature = num_sigs;
  for (LiteRtParamIndex i = 0; i < num_sigs; i++) {
    LiteRtSignature candidate = NULL;
    if (LiteRtGetModelSignature(model, i, &candidate) != kLiteRtStatusOk) continue;
    const char* key = NULL;
    if (signature && *signature &&
        (LiteRtGetSignatureKey(candidate, &key) != kLiteRtStatusOk || !key ||
         strcmp(key, signature) != 0)) continue;
    sig = candidate;
    s->signature = i;
    break;
  }
  if (!sig) {
    char msg[200];
    snprintf(msg, sizeof msg, "the model has no signature '%s'", signature ? signature : "");
    set_err(errbuf, errbuf_len, msg); goto fail;
  }

  LiteRtParamIndex num_in = 0, num_out = 0;
  LiteRtGetNumSignatureInputs(sig, &num_in);
  LiteRtGetNumSignatureOutputs(sig, &num_out);
  s->num_inputs = (int)num_in;
  s->num_outputs = (int)num_out;

  s->input_names = (char**)calloc((size_t)s->num_inputs, sizeof(char*));
  s->output_names = (char**)calloc((size_t)s->num_outputs, sizeof(char*));
  s->input_buffers = (LiteRtTensorBuffer*)calloc((size_t)s->num_inputs, sizeof(LiteRtTensorBuffer));
  s->output_buffers = (LiteRtTensorBuffer*)calloc((size_t)s->num_outputs, sizeof(LiteRtTensorBuffer));
  s->out_element = (int*)calloc((size_t)s->num_outputs, sizeof(int));
  s->out_rank = (int*)calloc((size_t)s->num_outputs, sizeof(int));
  s->out_dims = (int32_t*)calloc((size_t)s->num_outputs * LITERT_TENSOR_MAX_RANK, sizeof(int32_t));
  s->out_bytes = (size_t*)calloc((size_t)s->num_outputs, sizeof(size_t));
  s->out_copy = (void**)calloc((size_t)s->num_outputs, sizeof(void*));

  for (int i = 0; i < s->num_inputs; i++) {
    const char* name = NULL;
    if (LiteRtGetSignatureInputName(sig, (LiteRtParamIndex)i, &name) != kLiteRtStatusOk || !name) {
      set_err(errbuf, errbuf_len, "LiteRtGetSignatureInputName failed"); goto fail;
    }
    s->input_names[i] = copy_string(name);

    LiteRtTensor tensor = NULL;
    LiteRtRankedTensorType type;
    if (LiteRtGetSignatureInputTensorByIndex(sig, (LiteRtParamIndex)i, &tensor) != kLiteRtStatusOk ||
        LiteRtGetRankedTensorType(tensor, &type) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "reading input tensor type failed"); goto fail;
    }
    LiteRtTensorBufferRequirements reqs = NULL;
    if (LiteRtGetCompiledModelInputBufferRequirements(compiled, s->signature, (LiteRtParamIndex)i, &reqs)
            != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "input buffer requirements failed"); goto fail;
    }
    if (LiteRtCreateManagedTensorBufferFromRequirements(s->env, &type, reqs, &s->input_buffers[i])
            != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "create input buffer failed"); goto fail;
    }
  }

  for (int i = 0; i < s->num_outputs; i++) {
    const char* name = NULL;
    if (LiteRtGetSignatureOutputName(sig, (LiteRtParamIndex)i, &name) != kLiteRtStatusOk || !name) {
      set_err(errbuf, errbuf_len, "LiteRtGetSignatureOutputName failed"); goto fail;
    }
    s->output_names[i] = copy_string(name);

    LiteRtTensor tensor = NULL;
    LiteRtRankedTensorType type;
    if (LiteRtGetSignatureOutputTensorByIndex(sig, (LiteRtParamIndex)i, &tensor) != kLiteRtStatusOk ||
        LiteRtGetRankedTensorType(tensor, &type) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "reading output tensor type failed"); goto fail;
    }
    s->out_element[i] = (int)type.element_type;
    s->out_rank[i] = (int)type.layout.rank;
    for (unsigned int d = 0; d < type.layout.rank && d < LITERT_TENSOR_MAX_RANK; d++)
      s->out_dims[i * LITERT_TENSOR_MAX_RANK + d] = type.layout.dimensions[d];
    s->out_bytes[i] = layout_bytes(&type);

    LiteRtTensorBufferRequirements reqs = NULL;
    if (LiteRtGetCompiledModelOutputBufferRequirements(compiled, s->signature, (LiteRtParamIndex)i, &reqs)
            != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "output buffer requirements failed"); goto fail;
    }
    if (LiteRtCreateManagedTensorBufferFromRequirements(s->env, &type, reqs, &s->output_buffers[i])
            != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "create output buffer failed"); goto fail;
    }
    s->out_copy[i] = malloc(s->out_bytes[i] ? s->out_bytes[i] : 1);
  }

  return s;

fail:
  dal_lrt_free(s);
  return NULL;
}

int dal_lrt_num_inputs(const DalLrtSession* s) { return s ? s->num_inputs : 0; }
int dal_lrt_num_outputs(const DalLrtSession* s) { return s ? s->num_outputs : 0; }
const char* dal_lrt_input_name(const DalLrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_inputs) ? s->input_names[i] : NULL;
}
const char* dal_lrt_output_name(const DalLrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_outputs) ? s->output_names[i] : NULL;
}

int dal_lrt_run(DalLrtSession* s, const void* const* inputs, const size_t* input_lens,
                int num_inputs, char* errbuf, int errbuf_len) {
  if (!s || num_inputs != s->num_inputs) {
    set_err(errbuf, errbuf_len, "input count mismatch");
    return 1;
  }
  for (int i = 0; i < s->num_inputs; i++) {
    void* host = NULL;
    if (LiteRtLockTensorBuffer(s->input_buffers[i], &host, kLiteRtTensorBufferLockModeWrite)
            != kLiteRtStatusOk || !host) {
      set_err(errbuf, errbuf_len, "lock input buffer failed");
      return 2;
    }
    size_t cap = 0;
    LiteRtGetTensorBufferSize(s->input_buffers[i], &cap);
    size_t n = input_lens[i] < cap ? input_lens[i] : cap;
    memcpy(host, inputs[i], n);
    LiteRtUnlockTensorBuffer(s->input_buffers[i]);
  }

  mutex_lock(&s->shared->run_lock);
  LiteRtStatus run = LiteRtRunCompiledModel(s->shared->compiled, s->signature,
                                            (size_t)s->num_inputs, s->input_buffers,
                                            (size_t)s->num_outputs, s->output_buffers);
  mutex_unlock(&s->shared->run_lock);
  if (run != kLiteRtStatusOk) {
    set_err(errbuf, errbuf_len, "LiteRtRunCompiledModel failed");
    return 3;
  }

  for (int i = 0; i < s->num_outputs; i++) {
    void* host = NULL;
    if (LiteRtLockTensorBuffer(s->output_buffers[i], &host, kLiteRtTensorBufferLockModeRead)
            != kLiteRtStatusOk || !host) {
      set_err(errbuf, errbuf_len, "lock output buffer failed");
      return 4;
    }
    memcpy(s->out_copy[i], host, s->out_bytes[i]);
    LiteRtUnlockTensorBuffer(s->output_buffers[i]);
  }
  return 0;
}

int dal_lrt_output_element_type(const DalLrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_outputs) ? s->out_element[i] : 0;
}
int dal_lrt_output_rank(const DalLrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_outputs) ? s->out_rank[i] : 0;
}
void dal_lrt_output_dims(const DalLrtSession* s, int i, int32_t* dims_out) {
  if (!s || i < 0 || i >= s->num_outputs || !dims_out) return;
  for (int d = 0; d < s->out_rank[i]; d++) dims_out[d] = s->out_dims[i * LITERT_TENSOR_MAX_RANK + d];
}
size_t dal_lrt_output_byte_size(const DalLrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_outputs) ? s->out_bytes[i] : 0;
}
const void* dal_lrt_output_data(const DalLrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_outputs) ? s->out_copy[i] : NULL;
}
