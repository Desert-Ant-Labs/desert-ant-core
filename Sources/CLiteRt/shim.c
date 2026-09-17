#include "CLiteRt.h"

#include "litert/c/litert_opaque_options.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(__linux__) || defined(__ANDROID__)
#include <unistd.h>
#endif
#if defined(__ANDROID__)
#include <android/log.h>
#include <EGL/egl.h>
#endif

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define NOGDI
#include <windows.h>
static SRWLOCK g_env_lock = SRWLOCK_INIT;
#define ENV_LOCK() AcquireSRWLockExclusive(&g_env_lock)
#define ENV_UNLOCK() ReleaseSRWLockExclusive(&g_env_lock)
#else
#include <pthread.h>
static pthread_mutex_t g_env_lock = PTHREAD_MUTEX_INITIALIZER;
#define ENV_LOCK() pthread_mutex_lock(&g_env_lock)
#define ENV_UNLOCK() pthread_mutex_unlock(&g_env_lock)
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

// One compiled model with its fixed-shape input/output host buffers, created
// once and reused: each run writes inputs, invokes, and copies outputs out.

struct DalLrtSession {
  // The process-wide environment above (not owned), except on Android when the
  // GPU is requested: then a private environment carrying this session's EGL
  // context (owned, see owns_env), because an environment's options are fixed
  // at creation and the shared one must stay option-free.
  LiteRtEnvironment env;
  int owns_env;
  LiteRtModel model;
  LiteRtOptions options;
  LiteRtCompiledModel compiled;

  // Owned copy of the model bytes when created from a buffer. LiteRT's
  // LiteRtCreateModelFromBuffer is zero-copy ("the caller must ensure the
  // buffer remains valid for the lifetime of the model"), so we must keep the
  // bytes alive for as long as the model/compiled model reads them.
  void* model_data;

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

  // Input metadata (fixed shapes), so a caller can size its buffers from the
  // artifact rather than from a constant (e.g. Voz reads its decode lane count
  // off the decoder's embed input).
  int* in_element;
  int* in_rank;
  int32_t* in_dims;    // num_inputs * LITERT_TENSOR_MAX_RANK

  // A surfaceless EGL context of our own, created only when the caller asks
  // for the GPU on Android. LiteRT's GL backend allocates and maps tensor
  // buffers through whatever context the environment was given, and gives the
  // environment none by itself, which is why a GPU-compiled model's buffers
  // could not be created before this. NULL when unused (CPU, or EGL failed).
  void* egl_display;
  void* egl_context;
};

#if defined(__ANDROID__)
// Create the context and leave it current on this thread, so the compile and
// buffer creation that follow can use it. dal_lrt_run rebinds per call: GL
// contexts are thread-affine and the caller's threads are not ours to pin.
static int dal_egl_create(DalLrtSession* s) {
  EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (display == EGL_NO_DISPLAY || !eglInitialize(display, NULL, NULL)) return 1;
  const EGLint config_attrs[] = {
    EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
    EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
    EGL_NONE,
  };
  EGLConfig config;
  EGLint matched = 0;
  if (!eglChooseConfig(display, config_attrs, &config, 1, &matched) || matched < 1) return 1;
  const EGLint context_attrs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
  EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attrs);
  if (context == EGL_NO_CONTEXT) return 1;
  // Surfaceless current needs EGL_KHR_surfaceless_context, universal on the
  // Android versions this library supports.
  if (!eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context)) {
    eglDestroyContext(display, context);
    return 1;
  }
  s->egl_display = display;
  s->egl_context = context;
  return 0;
}

static void dal_egl_bind(const DalLrtSession* s) {
  if (s->egl_context)
    eglMakeCurrent((EGLDisplay)s->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                   (EGLContext)s->egl_context);
}

static void dal_egl_unbind(const DalLrtSession* s) {
  if (s->egl_context)
    eglMakeCurrent((EGLDisplay)s->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

static void dal_egl_free(DalLrtSession* s) {
  if (!s->egl_context) return;
  eglMakeCurrent((EGLDisplay)s->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  eglDestroyContext((EGLDisplay)s->egl_display, (EGLContext)s->egl_context);
  // The display is process-global and possibly shared; never eglTerminate it.
  s->egl_context = NULL;
  s->egl_display = NULL;
}
#else
static void dal_egl_bind(const DalLrtSession* s) { (void)s; }
static void dal_egl_unbind(const DalLrtSession* s) { (void)s; }
static void dal_egl_free(DalLrtSession* s) { (void)s; }
#endif

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
  free(s->in_element);
  free(s->in_rank);
  free(s->in_dims);
  if (s->compiled) LiteRtDestroyCompiledModel(s->compiled);
  if (s->options) LiteRtDestroyOptions(s->options);
  if (s->model) LiteRtDestroyModel(s->model);
  if (s->env && s->owns_env) LiteRtDestroyEnvironment(s->env);
  dal_egl_free(s);
  // Freed only after the model that references it is destroyed.
  free(s->model_data);
  free(s);
}

static char* copy_string(const char* s) {
  size_t n = strlen(s) + 1;
  char* out = (char*)malloc(n);
  if (out) memcpy(out, s, n);
  return out;
}

// A buffer the host cannot lock is useless to this shim whatever the runtime
// thinks of it: every run writes inputs and reads outputs through a host
// mapping. Probing at creation keeps that failure at load time, where the CPU
// fallback still applies, instead of at the first run, where nothing does.
static int dal_probe_lock(LiteRtTensorBuffer buffer) {
  void* host = NULL;
  if (LiteRtLockTensorBuffer(buffer, &host, kLiteRtTensorBufferLockModeWrite)
          != kLiteRtStatusOk || !host)
    return 1;
  LiteRtUnlockTensorBuffer(buffer);
  return 0;
}

// Create an I/O buffer satisfying `reqs`, preferring a kind the host can
// lock. A GPU-compiled model's requirements lead with device memory (a GL
// buffer wants a context this thread does not have, which is how the GPU
// path used to die at load), so the order is: AHWB when supported (host
// lockable, GPU visible, zero copy on Android), then plain host memory, then
// whatever the requirements prefer as the last resort.
static LiteRtStatus dal_create_io_buffer(DalLrtSession* s,
                                         const LiteRtRankedTensorType* type,
                                         LiteRtTensorBufferRequirements reqs,
                                         LiteRtTensorBuffer* out) {
  size_t size = 0;
  if (LiteRtGetTensorBufferRequirementsBufferSize(reqs, &size) != kLiteRtStatusOk || size == 0)
    size = layout_bytes(type);
  int n = 0;
  int has_host = 0, has_ahwb = 0, has_gl = 0;
  if (LiteRtGetNumTensorBufferRequirementsSupportedBufferTypes(reqs, &n) == kLiteRtStatusOk) {
    for (int i = 0; i < n; i++) {
      LiteRtTensorBufferType t = kLiteRtTensorBufferTypeUnknown;
      if (LiteRtGetTensorBufferRequirementsSupportedTensorBufferType(reqs, i, &t)
              != kLiteRtStatusOk) continue;
      if (t == kLiteRtTensorBufferTypeHostMemory) has_host = 1;
      if (t == kLiteRtTensorBufferTypeAhwb) has_ahwb = 1;
      if (t == kLiteRtTensorBufferTypeGlBuffer) has_gl = 1;
    }
  }
  // Each candidate must both create and lock; a kind that creates but cannot
  // be mapped (a GL buffer without a context, typically) is skipped.
  LiteRtTensorBufferType candidates[3];
  int num_candidates = 0;
#if defined(__ANDROID__)
  if (has_ahwb) candidates[num_candidates++] = kLiteRtTensorBufferTypeAhwb;
#endif
  if (has_host) candidates[num_candidates++] = kLiteRtTensorBufferTypeHostMemory;
  if (has_gl) candidates[num_candidates++] = kLiteRtTensorBufferTypeGlBuffer;
  for (int i = 0; i < num_candidates; i++) {
    LiteRtStatus made = LiteRtCreateManagedTensorBuffer(s->env, candidates[i], type, size, out);
    if (made != kLiteRtStatusOk) {
      char note[96];
      snprintf(note, sizeof(note), "buffer type %d: create status %d (egl %s)",
               (int)candidates[i], (int)made, s->egl_context ? "yes" : "no");
      dal_lrt_log(note);
      continue;
    }
    if (dal_probe_lock(*out) == 0) return kLiteRtStatusOk;
    dal_lrt_log("buffer created but probe lock failed");
    LiteRtDestroyTensorBuffer(*out);
    *out = NULL;
  }
  LiteRtStatus last = LiteRtCreateManagedTensorBufferFromRequirements(s->env, type, reqs, out);
  if (last == kLiteRtStatusOk && dal_probe_lock(*out) != 0) {
    LiteRtDestroyTensorBuffer(*out);
    *out = NULL;
    last = kLiteRtStatusErrorRuntimeFailure;
  }
  if (last != kLiteRtStatusOk) {
    // Which kinds the compiled model would accept, for the log: the number is
    // the LiteRtTensorBufferType enum (1 host, 2 ahwb, 6 GL buffer, ...).
    char note[160];
    int off = snprintf(note, sizeof(note), "io buffer creation failed; supported types:");
    for (int i = 0; i < n && off < (int)sizeof(note) - 8; i++) {
      LiteRtTensorBufferType t = kLiteRtTensorBufferTypeUnknown;
      if (LiteRtGetTensorBufferRequirementsSupportedTensorBufferType(reqs, i, &t) == kLiteRtStatusOk)
        off += snprintf(note + off, sizeof(note) - off, " %d", (int)t);
    }
    dal_lrt_log(note);
  }
  return last;
}

// Free everything one setup attempt allocated (options, compiled model, the
// tensor buffers and I/O metadata), leaving the environment and model alone so
// another attempt can reuse them. Pointers are nulled so a later dal_lrt_free
// cannot free them twice.
static void dal_teardown_setup(DalLrtSession* s) {
  if (s->input_buffers) {
    for (int i = 0; i < s->num_inputs; i++)
      if (s->input_buffers[i]) LiteRtDestroyTensorBuffer(s->input_buffers[i]);
    free(s->input_buffers); s->input_buffers = NULL;
  }
  if (s->output_buffers) {
    for (int i = 0; i < s->num_outputs; i++)
      if (s->output_buffers[i]) LiteRtDestroyTensorBuffer(s->output_buffers[i]);
    free(s->output_buffers); s->output_buffers = NULL;
  }
  if (s->input_names) {
    for (int i = 0; i < s->num_inputs; i++) free(s->input_names[i]);
    free(s->input_names); s->input_names = NULL;
  }
  if (s->output_names) {
    for (int i = 0; i < s->num_outputs; i++) free(s->output_names[i]);
    free(s->output_names); s->output_names = NULL;
  }
  if (s->out_copy) {
    for (int i = 0; i < s->num_outputs; i++) free(s->out_copy[i]);
    free(s->out_copy); s->out_copy = NULL;
  }
  free(s->out_element); s->out_element = NULL;
  free(s->out_rank); s->out_rank = NULL;
  free(s->out_dims); s->out_dims = NULL;
  free(s->out_bytes); s->out_bytes = NULL;
  free(s->in_element); s->in_element = NULL;
  free(s->in_rank); s->in_rank = NULL;
  free(s->in_dims); s->in_dims = NULL;
  s->num_inputs = 0;
  s->num_outputs = 0;
  if (s->compiled) { LiteRtDestroyCompiledModel(s->compiled); s->compiled = NULL; }
  if (s->options) { LiteRtDestroyOptions(s->options); s->options = NULL; }
}

// One full setup attempt at the given accelerator set: options, compile, and
// the fixed I/O tensor buffers. A GPU request can fail in two places - the
// compile, and the buffer creation afterwards, whose requirements a GPU
// compile can make unsatisfiable (an OpenGL buffer wants a context this
// thread does not have; seen on devices without OpenCL, where LiteRT falls
// back to its GL delegate) - so the CPU retry in dal_lrt_create wraps this
// whole function, not just the compile. Returns 0 on success.
static int dal_setup(DalLrtSession* s, LiteRtHwAcceleratorSet accel,
                     int num_threads, int gpu_precision,
                     char* errbuf, int errbuf_len) {
  if (LiteRtCreateOptions(&s->options) != kLiteRtStatusOk) {
    set_err(errbuf, errbuf_len, "LiteRtCreateOptions failed"); return 1;
  }
  LiteRtSetOptionsHardwareAccelerators(s->options, accel);
  // XNNPACK thread count. Without this the CPU accelerator runs
  // single-threaded, which is the difference between ~1x and ~10-30x
  // realtime on the encoder. Half the online cores approximates the big
  // cluster on current big.LITTLE phones without oversubscribing; capped
  // because XNNPACK gains nothing past the big cores and loses to sync
  // overhead beyond ~8. Payload is a TOML string parsed by the runtime's
  // ParseLiteRtCpuOptions (identifier "xnnpack"); it applies to the CPU
  // accelerator whether CPU was requested or is the fallback partition of
  // a GPU/NPU compile, so it is set on every attempt.
  {
    long n = num_threads;
    if (n <= 0) {
      n = 4;
#if defined(__linux__) || defined(__ANDROID__)
      long online = sysconf(_SC_NPROCESSORS_ONLN);
      if (online > 1) n = online / 2;
      if (n < 2) n = 2;
      if (n > 8) n = 8;
#endif
    }
    char* toml = (char*)malloc(32);
    if (toml) {
      snprintf(toml, 32, "num_threads = %ld", n);
      LiteRtOpaqueOptions cpu_opts = NULL;
      if (LiteRtCreateOpaqueOptions("xnnpack", toml, free, &cpu_opts) ==
          kLiteRtStatusOk) {
        // On success the options list owns cpu_opts (and cpu_opts owns
        // toml); on failure destroy it, which also frees toml.
        if (LiteRtAddOpaqueOptions(s->options, cpu_opts) != kLiteRtStatusOk)
          LiteRtDestroyOpaqueOptions(cpu_opts);
      } else {
        free(toml);
      }
    }
  }
  // GPU compute precision, as a LiteRtDelegatePrecision. The interesting
  // value is 3 (fp16 storage and math, fp32 accumulation): plain fp16 loses
  // the long dot products a transformer encoder is made of, and fp32 gives
  // the speed back.
  if ((accel & kLiteRtHwAcceleratorGpu) && gpu_precision > 0) {
    char* toml = (char*)malloc(32);
    if (toml) {
      snprintf(toml, 32, "precision = %d", gpu_precision);
      LiteRtOpaqueOptions gpu_opts = NULL;
      if (LiteRtCreateOpaqueOptions("gpu_options", toml, free, &gpu_opts) ==
          kLiteRtStatusOk) {
        if (LiteRtAddOpaqueOptions(s->options, gpu_opts) != kLiteRtStatusOk)
          LiteRtDestroyOpaqueOptions(gpu_opts);
      } else {
        free(toml);
      }
    }
  }
  if (LiteRtCreateCompiledModel(s->env, s->model, s->options, &s->compiled)
          != kLiteRtStatusOk) {
    set_err(errbuf, errbuf_len, "LiteRtCreateCompiledModel failed"); return 1;
  }

  // The compile above may have rebound this thread's EGL context (the ClGl
  // accelerator manages contexts of its own); the buffer creation below needs
  // ours current again.
  dal_egl_bind(s);

  // Names come from signature 0; tensor types from the main subgraph (index
  // aligned for our single-signature models).
  LiteRtSignature sig = NULL;
  if (LiteRtGetModelSignature(s->model, 0, &sig) != kLiteRtStatusOk) {
    set_err(errbuf, errbuf_len, "LiteRtGetModelSignature failed"); return 1;
  }
  LiteRtSubgraph subgraph = NULL;
  if (LiteRtGetModelSubgraph(s->model, 0, &subgraph) != kLiteRtStatusOk) {
    set_err(errbuf, errbuf_len, "LiteRtGetModelSubgraph failed"); return 1;
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
  s->in_element = (int*)calloc((size_t)s->num_inputs, sizeof(int));
  s->in_rank = (int*)calloc((size_t)s->num_inputs, sizeof(int));
  s->in_dims = (int32_t*)calloc((size_t)s->num_inputs * LITERT_TENSOR_MAX_RANK, sizeof(int32_t));

  for (int i = 0; i < s->num_inputs; i++) {
    const char* name = NULL;
    if (LiteRtGetSignatureInputName(sig, (LiteRtParamIndex)i, &name) != kLiteRtStatusOk || !name) {
      set_err(errbuf, errbuf_len, "LiteRtGetSignatureInputName failed"); return 1;
    }
    s->input_names[i] = copy_string(name);

    LiteRtTensor tensor = NULL;
    LiteRtRankedTensorType type;
    if (LiteRtGetSubgraphInput(subgraph, (LiteRtParamIndex)i, &tensor) != kLiteRtStatusOk ||
        LiteRtGetRankedTensorType(tensor, &type) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "reading input tensor type failed"); return 1;
    }
    s->in_element[i] = (int)type.element_type;
    s->in_rank[i] = (int)type.layout.rank;
    for (unsigned int d = 0; d < type.layout.rank && d < LITERT_TENSOR_MAX_RANK; d++)
      s->in_dims[i * LITERT_TENSOR_MAX_RANK + d] = type.layout.dimensions[d];
    LiteRtTensorBufferRequirements reqs = NULL;
    if (LiteRtGetCompiledModelInputBufferRequirements(s->compiled, 0, (LiteRtParamIndex)i, &reqs)
            != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "input buffer requirements failed"); return 1;
    }
    if (dal_create_io_buffer(s, &type, reqs, &s->input_buffers[i]) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "create input buffer failed"); return 1;
    }
  }

  for (int i = 0; i < s->num_outputs; i++) {
    const char* name = NULL;
    if (LiteRtGetSignatureOutputName(sig, (LiteRtParamIndex)i, &name) != kLiteRtStatusOk || !name) {
      set_err(errbuf, errbuf_len, "LiteRtGetSignatureOutputName failed"); return 1;
    }
    s->output_names[i] = copy_string(name);

    LiteRtTensor tensor = NULL;
    LiteRtRankedTensorType type;
    if (LiteRtGetSubgraphOutput(subgraph, (LiteRtParamIndex)i, &tensor) != kLiteRtStatusOk ||
        LiteRtGetRankedTensorType(tensor, &type) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "reading output tensor type failed"); return 1;
    }
    s->out_element[i] = (int)type.element_type;
    s->out_rank[i] = (int)type.layout.rank;
    for (unsigned int d = 0; d < type.layout.rank && d < LITERT_TENSOR_MAX_RANK; d++)
      s->out_dims[i * LITERT_TENSOR_MAX_RANK + d] = type.layout.dimensions[d];
    s->out_bytes[i] = layout_bytes(&type);

    LiteRtTensorBufferRequirements reqs = NULL;
    if (LiteRtGetCompiledModelOutputBufferRequirements(s->compiled, 0, (LiteRtParamIndex)i, &reqs)
            != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "output buffer requirements failed"); return 1;
    }
    if (dal_create_io_buffer(s, &type, reqs, &s->output_buffers[i]) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "create output buffer failed"); return 1;
    }
    s->out_copy[i] = malloc(s->out_bytes[i] ? s->out_bytes[i] : 1);
  }

  return 0;
}

DalLrtSession* dal_lrt_create(const char* path, const void* data, size_t data_len,
                              int accelerator, int num_threads, int gpu_precision,
                              char* errbuf, int errbuf_len) {
  DalLrtSession* s = (DalLrtSession*)calloc(1, sizeof(DalLrtSession));
  if (!s) { set_err(errbuf, errbuf_len, "out of memory"); return NULL; }

  // A GPU request on Android gets a private environment carrying this
  // session's EGL context: LiteRT's GL backend allocates and maps tensor
  // buffers through the environment's context and has none of its own, so
  // without this a GPU-compiled model's I/O buffers cannot be created and
  // every GPU request fell back to CPU. Environment options are fixed at
  // creation, so the context cannot ride the shared environment; everything
  // else uses the shared one (created once, so the accelerator registry logs
  // once).
#if defined(__ANDROID__)
  if (accelerator & 2) {
    if (dal_egl_create(s) != 0) {
      dal_lrt_log("egl context setup failed; GL buffers will be unavailable");
    }
    if (s->egl_context) {
      LiteRtEnvOption env_options[2];
      int num_env_options = 0;
      env_options[num_env_options].tag = kLiteRtEnvOptionTagEglDisplay;
      env_options[num_env_options].value.type = kLiteRtAnyTypeVoidPtr;
      env_options[num_env_options].value.ptr_value = s->egl_display;
      num_env_options++;
      env_options[num_env_options].tag = kLiteRtEnvOptionTagEglContext;
      env_options[num_env_options].value.type = kLiteRtAnyTypeVoidPtr;
      env_options[num_env_options].value.ptr_value = s->egl_context;
      num_env_options++;
      if (LiteRtCreateEnvironment(num_env_options, env_options, &s->env) == kLiteRtStatusOk) {
        s->owns_env = 1;
      } else {
        dal_lrt_log("private environment creation failed; GL buffers will be unavailable");
        dal_egl_free(s);
      }
    }
  }
#endif
  if (!s->env) s->env = shared_environment();
  if (!s->env) {
    set_err(errbuf, errbuf_len, "LiteRtCreateEnvironment failed"); goto fail;
  }
  if (path) {
    if (LiteRtCreateModelFromFile(s->env, path, &s->model) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "LiteRtCreateModelFromFile failed"); goto fail;
    }
  } else if (data && data_len > 0) {
    // Copy the bytes into a buffer we own: LiteRtCreateModelFromBuffer keeps a
    // zero-copy reference, and the caller's buffer (e.g. a Swift [UInt8] or a
    // JNI byte[]) is freed as soon as create returns, which would leave the
    // model's flatbuffer dangling and crash at run.
    s->model_data = malloc(data_len);
    if (!s->model_data) { set_err(errbuf, errbuf_len, "out of memory"); goto fail; }
    memcpy(s->model_data, data, data_len);
    if (LiteRtCreateModelFromBuffer(s->env, s->model_data, data_len, &s->model) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "LiteRtCreateModelFromBuffer failed"); goto fail;
    }
  } else {
    set_err(errbuf, errbuf_len, "no model path or bytes"); goto fail;
  }
  // Set up for the requested accelerator(s), falling back to CPU if any part
  // of it fails, so a preferred GPU/NPU (used automatically when its
  // accelerator library is bundled) never breaks model load on a device that
  // lacks it or whose driver rejects the model.
  LiteRtHwAcceleratorSet accel =
      accelerator ? (LiteRtHwAcceleratorSet)accelerator : kLiteRtHwAcceleratorCpu;
  if (dal_setup(s, accel, num_threads, gpu_precision, errbuf, errbuf_len) != 0) {
    if (errbuf) {
      char note[320];
      snprintf(note, sizeof(note), "accelerated setup failed (%s); retrying on CPU", errbuf);
      dal_lrt_log(note);
    }
    dal_teardown_setup(s);
    if (accel == kLiteRtHwAcceleratorCpu ||
        dal_setup(s, kLiteRtHwAcceleratorCpu, num_threads, 0, errbuf, errbuf_len) != 0) {
      goto fail;
    }
  }

  dal_egl_unbind(s);
  return s;

fail:
#if defined(__ANDROID__)
  // The message dies in the Swift binding on its way to Kotlin, so leave it
  // where a device log can find it.
  __android_log_print(ANDROID_LOG_ERROR, "desertant",
                      "dal_lrt_create: %s", errbuf ? errbuf : "unknown error");
#endif
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

void dal_lrt_log(const char* message) {
#if defined(__ANDROID__)
  __android_log_print(ANDROID_LOG_INFO, "desertant", "%s", message ? message : "");
#else
  if (message) fprintf(stderr, "%s\n", message);
#endif
}

int dal_lrt_input_element_type(const DalLrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_inputs) ? s->in_element[i] : 0;
}
int dal_lrt_input_rank(const DalLrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_inputs) ? s->in_rank[i] : 0;
}
void dal_lrt_input_dims(const DalLrtSession* s, int i, int32_t* dims_out) {
  if (!s || i < 0 || i >= s->num_inputs || !dims_out) return;
  for (int d = 0; d < s->in_rank[i]; d++)
    dims_out[d] = s->in_dims[i * LITERT_TENSOR_MAX_RANK + d];
}

static int dal_lrt_run_locked(DalLrtSession* s, const void* const* inputs, const size_t* input_lens,
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

  if (LiteRtRunCompiledModel(s->compiled, 0, (size_t)s->num_inputs, s->input_buffers,
                             (size_t)s->num_outputs, s->output_buffers) != kLiteRtStatusOk) {
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

int dal_lrt_run(DalLrtSession* s, const void* const* inputs, const size_t* input_lens,
                int num_inputs, char* errbuf, int errbuf_len) {
  // GL tensor buffers only map with the context current, and the caller's
  // thread changes between runs; bind around the whole run, then release so
  // another thread can bind next time.
  dal_egl_bind(s);
  int status = dal_lrt_run_locked(s, inputs, input_lens, num_inputs, errbuf, errbuf_len);
  dal_egl_unbind(s);
  return status;
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
