#include "CLiteRt.h"
#include "litert/c/litert_opaque_options.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(__ANDROID__)
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
#include <unistd.h>
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

// One compiled model, shared by the sessions of its signatures and freed with the
// last of them (or with the creator's reference, if it never made one).
struct DalLrtModel {
  // The process-wide environment above (not owned), except on Android when the
  // GPU is requested: then a private environment carrying this model's EGL
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

  int num_signatures;
  char** signature_keys;
  int refs;  // atomic: sessions are freed on whichever thread drops them

  // A surfaceless EGL context of our own, created only when the caller asks
  // for the GPU on Android. LiteRT's GL backend allocates and maps tensor
  // buffers through whatever context the environment was given, and gives the
  // environment none by itself. NULL when unused (CPU, or EGL failed).
  void* egl_display;
  void* egl_context;
};

// One signature of a model with its fixed-shape input/output buffers, created
// once and reused: each run writes inputs, invokes, and copies outputs out.
struct DalLrtSession {
  DalLrtModel* model;  // one reference
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

  // Input metadata (fixed shapes), so a caller can size its buffers from the
  // artifact rather than from a constant (e.g. Voz reads its decode lane count
  // off the decoder's embed input).
  int* in_element;
  int* in_rank;
  int32_t* in_dims;    // num_inputs * LITERT_TENSOR_MAX_RANK
};

#if defined(__ANDROID__)
// Create the context and leave it current on this thread, so the compile and
// buffer creation that follow can use it. dal_lrt_run rebinds per call: GL
// contexts are thread-affine and the caller's threads are not ours to pin.
static int dal_egl_create(DalLrtModel* m) {
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
  m->egl_display = display;
  m->egl_context = context;
  return 0;
}

static void dal_egl_bind(const DalLrtModel* m) {
  if (m->egl_context)
    eglMakeCurrent((EGLDisplay)m->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                   (EGLContext)m->egl_context);
}

static void dal_egl_unbind(const DalLrtModel* m) {
  if (m->egl_context)
    eglMakeCurrent((EGLDisplay)m->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

static void dal_egl_free(DalLrtModel* m) {
  if (!m->egl_context) return;
  eglMakeCurrent((EGLDisplay)m->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  eglDestroyContext((EGLDisplay)m->egl_display, (EGLContext)m->egl_context);
  // The display is process-global and possibly shared; never eglTerminate it.
  m->egl_context = NULL;
  m->egl_display = NULL;
}
#else
static void dal_egl_bind(const DalLrtModel* m) { (void)m; }
static void dal_egl_unbind(const DalLrtModel* m) { (void)m; }
static void dal_egl_free(DalLrtModel* m) { (void)m; }
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

static void model_free(DalLrtModel* m) {
  if (m->signature_keys) {
    for (int i = 0; i < m->num_signatures; i++) free(m->signature_keys[i]);
    free(m->signature_keys);
  }
  if (m->compiled) LiteRtDestroyCompiledModel(m->compiled);
  if (m->options) LiteRtDestroyOptions(m->options);
  if (m->model) LiteRtDestroyModel(m->model);
  if (m->env && m->owns_env) LiteRtDestroyEnvironment(m->env);
  dal_egl_free(m);
  // Freed only after the model that references it is destroyed.
  free(m->model_data);
  free(m);
}

void dal_lrt_model_release(DalLrtModel* m) {
  if (m && __atomic_sub_fetch(&m->refs, 1, __ATOMIC_ACQ_REL) == 0) model_free(m);
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
  // After the buffers: they were created against the model's compiled model.
  dal_lrt_model_release(s->model);
  free(s);
}

static char* copy_string(const char* s) {
  size_t n = strlen(s) + 1;
  char* out = (char*)malloc(n);
  if (out) memcpy(out, s, n);
  return out;
}

// XNNPACK threads. LiteRT's default is one, which leaves a transformer 3 to 6x
// slower than it needs to be. The caller's num_threads wins when positive (1 is
// right for graphs dispatched per step, where a thread pool costs more in
// synchronization than it computes); then DAL_LITERT_THREADS; then half the
// logical cores (one per physical core on SMT desktops, the big cores on most
// phones), at most 8, where scaling stops.
static int cpu_threads(int num_threads) {
  if (num_threads > 0) return num_threads;
  const char* env = getenv("DAL_LITERT_THREADS");
  if (env && atoi(env) > 0) return atoi(env);
#ifdef _WIN32
  SYSTEM_INFO info;
  GetSystemInfo(&info);
  long n = (long)info.dwNumberOfProcessors;
#else
  long n = sysconf(_SC_NPROCESSORS_ONLN);
#endif
  if (n < 1) return 1;
  if (n <= 4) return (int)n;
  return n / 2 > 8 ? 8 : (int)(n / 2);
}

// CPU options travel as an opaque entry holding TOML, as LiteRT's own
// LrtGetOpaqueCpuOptionsData builds it (that helper is not exported by the
// runtime library). Its identifier was "xnnpack" through 2.1 and is
// "cpu_options" since; each version ignores the other's. A failure leaves
// LiteRT's defaults.
static void add_toml_option(LiteRtOptions options, const char* identifier, char* toml) {
  LiteRtOpaqueOptions opaque = NULL;
  if (LiteRtCreateOpaqueOptions(identifier, toml, free, &opaque) != kLiteRtStatusOk) {
    free(toml);
    return;
  }
  // On success the options list owns `opaque` (and `opaque` owns toml); on
  // failure destroy it, which also frees toml.
  if (LiteRtAddOpaqueOptions(options, opaque) != kLiteRtStatusOk) LiteRtDestroyOpaqueOptions(opaque);
}

static void add_cpu_option(LiteRtOptions options, const char* identifier, int num_threads) {
  char* toml = (char*)malloc(32);
  if (!toml) return;
  snprintf(toml, 32, "num_threads = %d\n", cpu_threads(num_threads));
  add_toml_option(options, identifier, toml);
}

// The CPU thread count applies whether CPU was requested or is the fallback
// partition of a GPU/NPU compile, so it is set on every attempt.
static void add_cpu_options(LiteRtOptions options, int num_threads) {
  add_cpu_option(options, "xnnpack", num_threads);
  add_cpu_option(options, "cpu_options", num_threads);
}

// GPU compute precision, as a LiteRtDelegatePrecision. The interesting values
// are 2 (fp32) and 3 (fp16 storage and math, fp32 accumulation): plain fp16
// loses the long dot products a transformer encoder is made of, and fp32
// accumulation gives the accuracy back.
static void add_gpu_options(LiteRtOptions options, int gpu_precision) {
  char* toml = (char*)malloc(32);
  if (!toml) return;
  snprintf(toml, 32, "precision = %d", gpu_precision);
  add_toml_option(options, "gpu_options", toml);
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
// buffer wants a context this thread may not have), so the order is: AHWB
// when supported (host
// lockable, GPU visible, zero copy on Android), then plain host memory, then
// whatever the requirements prefer as the last resort.
static LiteRtStatus dal_create_io_buffer(DalLrtModel* m,
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
#else
  (void)has_ahwb;
#endif
  if (has_host) candidates[num_candidates++] = kLiteRtTensorBufferTypeHostMemory;
  if (has_gl) candidates[num_candidates++] = kLiteRtTensorBufferTypeGlBuffer;
  for (int i = 0; i < num_candidates; i++) {
    LiteRtStatus made = LiteRtCreateManagedTensorBuffer(m->env, candidates[i], type, size, out);
    if (made != kLiteRtStatusOk) continue;
    if (dal_probe_lock(*out) == 0) return kLiteRtStatusOk;
    LiteRtDestroyTensorBuffer(*out);
    *out = NULL;
  }
  LiteRtStatus last = LiteRtCreateManagedTensorBufferFromRequirements(m->env, type, reqs, out);
  if (last == kLiteRtStatusOk && dal_probe_lock(*out) != 0) {
    LiteRtDestroyTensorBuffer(*out);
    *out = NULL;
    last = kLiteRtStatusErrorRuntimeFailure;
  }
  return last;
}

// One compile attempt at the given accelerator set: options, then the compiled
// model. Returns 0 on success, leaving m->options and m->compiled set.
static int model_compile(DalLrtModel* m, LiteRtHwAcceleratorSet accel,
                         int num_threads, int gpu_precision,
                         char* errbuf, int errbuf_len) {
  if (LiteRtCreateOptions(&m->options) != kLiteRtStatusOk) {
    set_err(errbuf, errbuf_len, "LiteRtCreateOptions failed"); return 1;
  }
  LiteRtSetOptionsHardwareAccelerators(m->options, accel);
  add_cpu_options(m->options, num_threads);
  if ((accel & kLiteRtHwAcceleratorGpu) && gpu_precision > 0)
    add_gpu_options(m->options, gpu_precision);
  if (LiteRtCreateCompiledModel(m->env, m->model, m->options, &m->compiled)
          != kLiteRtStatusOk) {
    if (m->compiled) { LiteRtDestroyCompiledModel(m->compiled); m->compiled = NULL; }
    LiteRtDestroyOptions(m->options); m->options = NULL;
    set_err(errbuf, errbuf_len, "LiteRtCreateCompiledModel failed"); return 1;
  }
  return 0;
}

// Probe that the compiled model's I/O buffers can actually be created and
// host-mapped, by opening (and discarding) a session over signature 0. A GPU
// compile can succeed and still make the buffer requirements unsatisfiable (an
// OpenGL buffer wants a context this thread does not have; seen on devices
// without OpenCL, where LiteRT falls back to its GL delegate), so the CPU retry
// in dal_lrt_model_create wraps this probe as well as the compile. Returns 0 on
// success.
static int model_probe_buffers(DalLrtModel* m, char* errbuf, int errbuf_len) {
  DalLrtSession* probe = dal_lrt_session_create(m, NULL, errbuf, errbuf_len);
  if (!probe) return 1;
  dal_lrt_free(probe);
  return 0;
}

DalLrtModel* dal_lrt_model_create(const char* path, const void* data, size_t data_len,
                                  int accelerator, int num_threads, int gpu_precision,
                                  char* errbuf, int errbuf_len) {
  DalLrtModel* m = (DalLrtModel*)calloc(1, sizeof(DalLrtModel));
  if (!m) { set_err(errbuf, errbuf_len, "out of memory"); return NULL; }
  m->refs = 1;

  // A GPU request on Android gets a private environment carrying this model's
  // EGL context: LiteRT's GL backend allocates and maps tensor buffers through
  // the environment's context and has none of its own, so without this a
  // GPU-compiled model's I/O buffers cannot be created and every GPU request
  // quietly falls back to CPU. Environment options are fixed at creation, so the
  // context cannot ride the shared environment; everything else uses the
  // shared one (created once, so the accelerator registry logs once).
#if defined(__ANDROID__)
  if (accelerator & 2) {
    // A failed EGL setup is silent: GL buffers are simply unavailable and
    // buffer negotiation falls back to host memory.
    dal_egl_create(m);
    if (m->egl_context) {
      LiteRtEnvOption env_options[2];
      int num_env_options = 0;
      env_options[num_env_options].tag = kLiteRtEnvOptionTagEglDisplay;
      env_options[num_env_options].value.type = kLiteRtAnyTypeVoidPtr;
      env_options[num_env_options].value.ptr_value = m->egl_display;
      num_env_options++;
      env_options[num_env_options].tag = kLiteRtEnvOptionTagEglContext;
      env_options[num_env_options].value.type = kLiteRtAnyTypeVoidPtr;
      env_options[num_env_options].value.ptr_value = m->egl_context;
      num_env_options++;
      if (LiteRtCreateEnvironment(num_env_options, env_options, &m->env) == kLiteRtStatusOk) {
        m->owns_env = 1;
      } else {
        dal_egl_free(m);
      }
    }
  }
#endif
  if (!m->env) m->env = shared_environment();
  if (!m->env) {
    set_err(errbuf, errbuf_len, "LiteRtCreateEnvironment failed"); goto fail;
  }
  if (path) {
    if (LiteRtCreateModelFromFile(m->env, path, &m->model) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "LiteRtCreateModelFromFile failed"); goto fail;
    }
  } else if (data && data_len > 0) {
    // Copy the bytes into a buffer we own: LiteRtCreateModelFromBuffer keeps a
    // zero-copy reference, and the caller's buffer (e.g. a Swift [UInt8] or a
    // JNI byte[]) is freed as soon as create returns, which would leave the
    // model's flatbuffer dangling and crash at run.
    m->model_data = malloc(data_len);
    if (!m->model_data) { set_err(errbuf, errbuf_len, "out of memory"); goto fail; }
    memcpy(m->model_data, data, data_len);
    if (LiteRtCreateModelFromBuffer(m->env, m->model_data, data_len, &m->model) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "LiteRtCreateModelFromBuffer failed"); goto fail;
    }
  } else {
    set_err(errbuf, errbuf_len, "no model path or bytes"); goto fail;
  }

  {
    LiteRtParamIndex num_sigs = 0;
    if (LiteRtGetNumModelSignatures(m->model, &num_sigs) != kLiteRtStatusOk || num_sigs == 0) {
      set_err(errbuf, errbuf_len, "the model has no signatures"); goto fail;
    }
    m->num_signatures = (int)num_sigs;
  }
  m->signature_keys = (char**)calloc((size_t)m->num_signatures, sizeof(char*));
  if (!m->signature_keys) { set_err(errbuf, errbuf_len, "out of memory"); goto fail; }
  for (int i = 0; i < m->num_signatures; i++) {
    LiteRtSignature sig = NULL;
    const char* key = NULL;
    if (LiteRtGetModelSignature(m->model, (LiteRtParamIndex)i, &sig) != kLiteRtStatusOk ||
        LiteRtGetSignatureKey(sig, &key) != kLiteRtStatusOk || !key) {
      set_err(errbuf, errbuf_len, "reading a signature key failed"); goto fail;
    }
    m->signature_keys[i] = copy_string(key);
  }

  // Set up for the requested accelerator(s), falling back to CPU if any part
  // of it fails (the compile, or the buffer probe after it), so a preferred
  // GPU/NPU (used automatically when its accelerator library is bundled) never
  // breaks model load on a device that lacks it or whose driver rejects the
  // model. Ops the accelerator cannot run are already partitioned onto CPU by
  // LiteRT; this guards a hard failure.
  {
    LiteRtHwAcceleratorSet accel =
        accelerator ? (LiteRtHwAcceleratorSet)accelerator : kLiteRtHwAcceleratorCpu;
    if (model_compile(m, accel, num_threads, gpu_precision, errbuf, errbuf_len) != 0 ||
        model_probe_buffers(m, errbuf, errbuf_len) != 0) {
      if (m->compiled) { LiteRtDestroyCompiledModel(m->compiled); m->compiled = NULL; }
      if (m->options) { LiteRtDestroyOptions(m->options); m->options = NULL; }
      if (accel == kLiteRtHwAcceleratorCpu ||
          model_compile(m, kLiteRtHwAcceleratorCpu, num_threads, 0, errbuf, errbuf_len) != 0) {
        goto fail;
      }
    }
  }

  dal_egl_unbind(m);
  return m;

fail:
  model_free(m);
  return NULL;
}

int dal_lrt_model_num_signatures(const DalLrtModel* m) { return m ? m->num_signatures : 0; }
const char* dal_lrt_model_signature_key(const DalLrtModel* m, int i) {
  return (m && i >= 0 && i < m->num_signatures) ? m->signature_keys[i] : NULL;
}

DalLrtSession* dal_lrt_session_create(DalLrtModel* model, const char* signature,
                                      char* errbuf, int errbuf_len) {
  if (!model) { set_err(errbuf, errbuf_len, "no model"); return NULL; }
  int index = 0;
  if (signature) {
    index = -1;
    for (int i = 0; i < model->num_signatures; i++)
      if (strcmp(model->signature_keys[i], signature) == 0) index = i;
    if (index < 0) { set_err(errbuf, errbuf_len, "the model has no such signature"); return NULL; }
  }
  DalLrtSession* s = (DalLrtSession*)calloc(1, sizeof(DalLrtSession));
  if (!s) { set_err(errbuf, errbuf_len, "out of memory"); return NULL; }
  __atomic_add_fetch(&model->refs, 1, __ATOMIC_ACQ_REL);
  s->model = model;
  s->signature = (LiteRtParamIndex)index;

  // Buffer creation may touch GL, which needs the model's EGL context current
  // on this thread (the compile may have rebound it; the ClGl accelerator
  // manages contexts of its own).
  dal_egl_bind(model);

  LiteRtSignature sig = NULL;
  if (LiteRtGetModelSignature(model->model, s->signature, &sig) != kLiteRtStatusOk) {
    set_err(errbuf, errbuf_len, "LiteRtGetModelSignature failed"); goto fail;
  }

  {
    LiteRtParamIndex num_in = 0, num_out = 0;
    LiteRtGetNumSignatureInputs(sig, &num_in);
    LiteRtGetNumSignatureOutputs(sig, &num_out);
    s->num_inputs = (int)num_in;
    s->num_outputs = (int)num_out;
  }

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
      set_err(errbuf, errbuf_len, "LiteRtGetSignatureInputName failed"); goto fail;
    }
    s->input_names[i] = copy_string(name);

    LiteRtTensor tensor = NULL;
    LiteRtRankedTensorType type;
    if (LiteRtGetSignatureInputTensorByIndex(sig, (LiteRtParamIndex)i, &tensor) != kLiteRtStatusOk ||
        LiteRtGetRankedTensorType(tensor, &type) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "reading input tensor type failed"); goto fail;
    }
    s->in_element[i] = (int)type.element_type;
    s->in_rank[i] = (int)type.layout.rank;
    for (unsigned int d = 0; d < type.layout.rank && d < LITERT_TENSOR_MAX_RANK; d++)
      s->in_dims[i * LITERT_TENSOR_MAX_RANK + d] = type.layout.dimensions[d];
    LiteRtTensorBufferRequirements reqs = NULL;
    if (LiteRtGetCompiledModelInputBufferRequirements(s->model->compiled, s->signature, (LiteRtParamIndex)i, &reqs)
            != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "input buffer requirements failed"); goto fail;
    }
    if (dal_create_io_buffer(s->model, &type, reqs, &s->input_buffers[i]) != kLiteRtStatusOk) {
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
    if (LiteRtGetCompiledModelOutputBufferRequirements(s->model->compiled, s->signature, (LiteRtParamIndex)i, &reqs)
            != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "output buffer requirements failed"); goto fail;
    }
    if (dal_create_io_buffer(s->model, &type, reqs, &s->output_buffers[i]) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "create output buffer failed"); goto fail;
    }
    s->out_copy[i] = malloc(s->out_bytes[i] ? s->out_bytes[i] : 1);
  }

  dal_egl_unbind(model);
  return s;

fail:
  dal_egl_unbind(model);
  dal_lrt_free(s);
  return NULL;
}

DalLrtSession* dal_lrt_create(const char* path, const void* data, size_t data_len,
                              int accelerator, int num_threads, int gpu_precision,
                              char* errbuf, int errbuf_len) {
  DalLrtModel* m = dal_lrt_model_create(path, data, data_len, accelerator,
                                        num_threads, gpu_precision, errbuf, errbuf_len);
  if (!m) return NULL;
  DalLrtSession* s = dal_lrt_session_create(m, NULL, errbuf, errbuf_len);
  dal_lrt_model_release(m);  // the session holds its own reference
  return s;
}

int dal_lrt_num_inputs(const DalLrtSession* s) { return s ? s->num_inputs : 0; }
int dal_lrt_num_outputs(const DalLrtSession* s) { return s ? s->num_outputs : 0; }
const char* dal_lrt_input_name(const DalLrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_inputs) ? s->input_names[i] : NULL;
}
const char* dal_lrt_output_name(const DalLrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_outputs) ? s->output_names[i] : NULL;
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

  if (LiteRtRunCompiledModel(s->model->compiled, s->signature, (size_t)s->num_inputs, s->input_buffers,
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
  // another thread can bind next time. (The caller already serializes runs
  // across a model's sessions.)
  if (s) dal_egl_bind(s->model);
  int status = dal_lrt_run_locked(s, inputs, input_lens, num_inputs, errbuf, errbuf_len);
  if (s) dal_egl_unbind(s->model);
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
