// MSVC deprecates getenv and strncpy in favour of _s variants that do not exist
// off Windows. This shim builds for more than one toolchain, so it keeps the
// standard spellings and turns the warning off rather than forking the code.
#define _CRT_SECURE_NO_WARNINGS 1

#include "COnnxRuntime.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#endif

// One session with its input/output names and an owned copy of the last run's
// outputs, so Swift reads plain bytes after `dal_ort_run` returns rather than
// holding OrtValues across the language boundary.

struct DalOrtSession {
  const OrtApi* api;
  OrtEnv* env;
  OrtSessionOptions* options;
  OrtSession* session;
  OrtMemoryInfo* memory;
  OrtAllocator* allocator;

  int num_inputs;
  int num_outputs;
  char** input_names;
  char** output_names;
  int accelerators;

  // Output metadata plus an owned copy of the data, refreshed by each run.
  int* out_element;
  int* out_rank;
  int64_t* out_dims;   // num_outputs * DAL_ORT_MAX_RANK
  size_t* out_bytes;
  void** out_copy;
};

static void set_err(char* errbuf, int len, const char* msg) {
  if (errbuf && len > 0) {
    strncpy(errbuf, msg, (size_t)(len - 1));
    errbuf[len - 1] = '\0';
  }
}

// Turn an OrtStatus into a message and free it. Returns 1 when there was an
// error, so callers read as `if (check(...)) goto fail;`.
static int check(const OrtApi* api, OrtStatus* status, char* errbuf, int len,
                 const char* context) {
  if (!status) return 0;
  const char* msg = api->GetErrorMessage(status);
  if (errbuf && len > 0) {
    snprintf(errbuf, (size_t)len, "%s: %s", context, msg ? msg : "unknown");
  }
  api->ReleaseStatus(status);
  return 1;
}

static char* copy_string(const char* s) {
  size_t n = strlen(s) + 1;
  char* out = (char*)malloc(n);
  if (out) memcpy(out, s, n);
  return out;
}

#ifdef _WIN32
// ORT takes wide paths on Windows. Caller frees.
static wchar_t* widen(const char* s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
  if (n <= 0) return NULL;
  wchar_t* w = (wchar_t*)malloc((size_t)n * sizeof(wchar_t));
  if (w) MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
  return w;
}
#endif

// ONNX tensor element type -> the code CLiteRt uses, so Swift keeps one mapping.
static int element_code(ONNXTensorElementDataType t) {
  switch (t) {
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT: return 1;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32: return 2;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64: return 4;
    default: return 0;
  }
}

static ONNXTensorElementDataType onnx_type(int code) {
  switch (code) {
    case 2: return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32;
    case 4: return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64;
    default: return ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
  }
}

void dal_ort_free(DalOrtSession* s) {
  if (!s) return;
  const OrtApi* api = s->api;
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
  if (api) {
    if (s->memory) api->ReleaseMemoryInfo(s->memory);
    if (s->session) api->ReleaseSession(s->session);
    if (s->options) api->ReleaseSessionOptions(s->options);
    if (s->env) api->ReleaseEnv(s->env);
  }
  free(s);
}

// Select every device of `kind` that ORT already knows about onto `options`.
// Returns 1 if at least one was added. Used for the GPU, which the DirectML
// build reports without any registration step, unlike the NPU.
static int select_devices(DalOrtSession* s, OrtHardwareDeviceType kind) {
  const OrtApi* api = s->api;
  const OrtEpDevice* const* devices = NULL;
  size_t count = 0;
  OrtStatus* status = api->GetEpDevices(s->env, &devices, &count);
  if (status) { api->ReleaseStatus(status); return 0; }

  const OrtEpDevice* chosen[8];
  size_t n = 0;
  for (size_t i = 0; i < count && n < 8; i++) {
    const OrtHardwareDevice* hw = api->EpDevice_Device(devices[i]);
    if (hw && api->HardwareDevice_Type(hw) == kind) chosen[n++] = devices[i];
  }
  if (n == 0) return 0;
  status = api->SessionOptionsAppendExecutionProvider_V2(
      s->options, s->env, chosen, n, NULL, NULL, 0);
  if (status) { api->ReleaseStatus(status); return 0; }
  return 1;
}

static int select_gpu(DalOrtSession* s) {
  return select_devices(s, OrtHardwareDeviceType_GPU);
}

// Register the NPU provider and select its devices onto `options`. Returns 1 if
// an NPU device was selected. Failure is deliberately soft: a machine without
// the provider, or with one that refuses to load, should still get a working
// CPU session rather than no session at all.
static int select_npu(DalOrtSession* s, const char* library) {
  const OrtApi* api = s->api;
  if (!library || !*library) library = getenv("DAL_ORT_NPU_EP");
  if (!library || !*library) return 0;

#ifdef _WIN32
  wchar_t* wlib = widen(library);
  if (!wlib) return 0;
  OrtStatus* status = api->RegisterExecutionProviderLibrary(s->env, "dal_npu", wlib);
  free(wlib);
#else
  OrtStatus* status = api->RegisterExecutionProviderLibrary(s->env, "dal_npu", library);
#endif
  if (status) { api->ReleaseStatus(status); return 0; }

  return select_devices(s, OrtHardwareDeviceType_NPU);
}

DalOrtSession* dal_ort_create(const char* path, int accelerator,
                              const char* npu_ep_library,
                              char* errbuf, int errbuf_len) {
  if (!path || !*path) { set_err(errbuf, errbuf_len, "no model path"); return NULL; }

  DalOrtSession* s = (DalOrtSession*)calloc(1, sizeof(DalOrtSession));
  if (!s) { set_err(errbuf, errbuf_len, "out of memory"); return NULL; }

  s->api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
  if (!s->api) {
    set_err(errbuf, errbuf_len, "ONNX Runtime API version mismatch");
    goto fail;
  }
  const OrtApi* api = s->api;

  if (check(api, api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "desert-ant", &s->env),
            errbuf, errbuf_len, "CreateEnv")) goto fail;
  if (check(api, api->CreateSessionOptions(&s->options),
            errbuf, errbuf_len, "CreateSessionOptions")) goto fail;

  if (accelerator & DAL_ORT_GPU && select_gpu(s)) s->accelerators |= DAL_ORT_GPU;
  if (accelerator & DAL_ORT_NPU && select_npu(s, npu_ep_library))
    s->accelerators |= DAL_ORT_NPU;

#ifdef _WIN32
  wchar_t* wpath = widen(path);
  if (!wpath) { set_err(errbuf, errbuf_len, "cannot widen model path"); goto fail; }
  OrtStatus* st = api->CreateSession(s->env, wpath, s->options, &s->session);
  free(wpath);
#else
  OrtStatus* st = api->CreateSession(s->env, path, s->options, &s->session);
#endif
  if (check(api, st, errbuf, errbuf_len, "CreateSession")) goto fail;

  if (check(api, api->GetAllocatorWithDefaultOptions(&s->allocator),
            errbuf, errbuf_len, "GetAllocator")) goto fail;
  if (check(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &s->memory),
            errbuf, errbuf_len, "CreateCpuMemoryInfo")) goto fail;

  size_t n_in = 0, n_out = 0;
  if (check(api, api->SessionGetInputCount(s->session, &n_in),
            errbuf, errbuf_len, "SessionGetInputCount")) goto fail;
  if (check(api, api->SessionGetOutputCount(s->session, &n_out),
            errbuf, errbuf_len, "SessionGetOutputCount")) goto fail;
  s->num_inputs = (int)n_in;
  s->num_outputs = (int)n_out;

  s->input_names = (char**)calloc((size_t)s->num_inputs, sizeof(char*));
  s->output_names = (char**)calloc((size_t)s->num_outputs, sizeof(char*));
  s->out_element = (int*)calloc((size_t)s->num_outputs, sizeof(int));
  s->out_rank = (int*)calloc((size_t)s->num_outputs, sizeof(int));
  s->out_dims = (int64_t*)calloc((size_t)s->num_outputs * DAL_ORT_MAX_RANK, sizeof(int64_t));
  s->out_bytes = (size_t*)calloc((size_t)s->num_outputs, sizeof(size_t));
  s->out_copy = (void**)calloc((size_t)s->num_outputs, sizeof(void*));
  if (!s->input_names || !s->output_names || !s->out_element || !s->out_rank ||
      !s->out_dims || !s->out_bytes || !s->out_copy) {
    set_err(errbuf, errbuf_len, "out of memory");
    goto fail;
  }

  // ORT hands back allocator-owned name strings; copy them so the session owns
  // names with the same lifetime as itself, then give ORT's copies back.
  for (int i = 0; i < s->num_inputs; i++) {
    char* name = NULL;
    if (check(api, api->SessionGetInputName(s->session, (size_t)i, s->allocator, &name),
              errbuf, errbuf_len, "SessionGetInputName")) goto fail;
    s->input_names[i] = copy_string(name);
    api->AllocatorFree(s->allocator, name);
  }
  for (int i = 0; i < s->num_outputs; i++) {
    char* name = NULL;
    if (check(api, api->SessionGetOutputName(s->session, (size_t)i, s->allocator, &name),
              errbuf, errbuf_len, "SessionGetOutputName")) goto fail;
    s->output_names[i] = copy_string(name);
    api->AllocatorFree(s->allocator, name);
  }

  return s;

fail:
  dal_ort_free(s);
  return NULL;
}

int dal_ort_num_inputs(const DalOrtSession* s) { return s ? s->num_inputs : 0; }
int dal_ort_num_outputs(const DalOrtSession* s) { return s ? s->num_outputs : 0; }
int dal_ort_accelerators(const DalOrtSession* s) { return s ? s->accelerators : 0; }

const char* dal_ort_input_name(const DalOrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_inputs) ? s->input_names[i] : NULL;
}
const char* dal_ort_output_name(const DalOrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_outputs) ? s->output_names[i] : NULL;
}

int dal_ort_run(DalOrtSession* s,
                const void* const* inputs, const size_t* input_lens,
                const int64_t* dims, const int32_t* ranks,
                const int32_t* elements, int num_inputs,
                char* errbuf, int errbuf_len) {
  if (!s || num_inputs != s->num_inputs) {
    set_err(errbuf, errbuf_len, "input count mismatch");
    return 1;
  }
  const OrtApi* api = s->api;
  int rc = 0;

  OrtValue** in_values = (OrtValue**)calloc((size_t)num_inputs, sizeof(OrtValue*));
  OrtValue** out_values = (OrtValue**)calloc((size_t)s->num_outputs, sizeof(OrtValue*));
  if (!in_values || !out_values) {
    set_err(errbuf, errbuf_len, "out of memory");
    free(in_values); free(out_values);
    return 2;
  }

  // Tensors wrap the caller's buffers rather than copying: ORT does not take
  // ownership, and the Swift side keeps them pinned for the length of the call.
  for (int i = 0; i < num_inputs; i++) {
    OrtStatus* st = api->CreateTensorWithDataAsOrtValue(
        s->memory, (void*)inputs[i], input_lens[i],
        dims + (size_t)i * DAL_ORT_MAX_RANK, (size_t)ranks[i],
        onnx_type(elements[i]), &in_values[i]);
    if (check(api, st, errbuf, errbuf_len, "CreateTensorWithDataAsOrtValue")) {
      rc = 3; goto done;
    }
  }

  OrtStatus* st = api->Run(s->session, NULL,
                           (const char* const*)s->input_names, (const OrtValue* const*)in_values,
                           (size_t)num_inputs,
                           (const char* const*)s->output_names, (size_t)s->num_outputs,
                           out_values);
  if (check(api, st, errbuf, errbuf_len, "Run")) { rc = 4; goto done; }

  for (int i = 0; i < s->num_outputs; i++) {
    OrtTensorTypeAndShapeInfo* info = NULL;
    if (check(api, api->GetTensorTypeAndShape(out_values[i], &info),
              errbuf, errbuf_len, "GetTensorTypeAndShape")) { rc = 5; goto done; }

    ONNXTensorElementDataType et = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    size_t rank = 0, count = 0;
    api->GetTensorElementType(info, &et);
    api->GetDimensionsCount(info, &rank);
    api->GetTensorShapeElementCount(info, &count);
    if (rank > DAL_ORT_MAX_RANK) rank = DAL_ORT_MAX_RANK;
    int64_t shape[DAL_ORT_MAX_RANK];
    api->GetDimensions(info, shape, rank);
    api->ReleaseTensorTypeAndShapeInfo(info);

    s->out_element[i] = element_code(et);
    if (s->out_element[i] == 0) {
      set_err(errbuf, errbuf_len, "unsupported ONNX output element type");
      rc = 6; goto done;
    }
    s->out_rank[i] = (int)rank;
    for (size_t d = 0; d < rank; d++) s->out_dims[(size_t)i * DAL_ORT_MAX_RANK + d] = shape[d];

    size_t width = s->out_element[i] == 4 ? 8 : 4;
    size_t bytes = count * width;
    // Outputs are copied out because the OrtValues are released below, and a
    // shape can change between runs when a graph has a dynamic axis.
    if (bytes != s->out_bytes[i] || !s->out_copy[i]) {
      free(s->out_copy[i]);
      s->out_copy[i] = malloc(bytes ? bytes : 1);
      if (!s->out_copy[i]) { set_err(errbuf, errbuf_len, "out of memory"); rc = 7; goto done; }
      s->out_bytes[i] = bytes;
    }
    void* data = NULL;
    if (check(api, api->GetTensorMutableData(out_values[i], &data),
              errbuf, errbuf_len, "GetTensorMutableData")) { rc = 8; goto done; }
    if (data && bytes) memcpy(s->out_copy[i], data, bytes);
  }

done:
  for (int i = 0; i < num_inputs; i++)
    if (in_values[i]) api->ReleaseValue(in_values[i]);
  for (int i = 0; i < s->num_outputs; i++)
    if (out_values[i]) api->ReleaseValue(out_values[i]);
  free(in_values);
  free(out_values);
  return rc;
}

int dal_ort_run_bound(DalOrtSession* s,
                      const void* const* inputs, const size_t* input_lens,
                      const int64_t* in_dims, const int32_t* in_ranks,
                      const int32_t* in_elements, int num_inputs,
                      void* const* outputs, const size_t* output_lens,
                      const int64_t* out_dims, const int32_t* out_ranks,
                      const int32_t* out_elements, int num_outputs,
                      char* errbuf, int errbuf_len) {
  if (!s || num_inputs != s->num_inputs || num_outputs != s->num_outputs) {
    set_err(errbuf, errbuf_len, "input or output count mismatch");
    return 1;
  }
  const OrtApi* api = s->api;
  int rc = 0;

  OrtValue** in_values = (OrtValue**)calloc((size_t)num_inputs, sizeof(OrtValue*));
  OrtValue** out_values = (OrtValue**)calloc((size_t)num_outputs, sizeof(OrtValue*));
  if (!in_values || !out_values) {
    set_err(errbuf, errbuf_len, "out of memory");
    free(in_values); free(out_values);
    return 2;
  }

  for (int i = 0; i < num_inputs; i++) {
    OrtStatus* st = api->CreateTensorWithDataAsOrtValue(
        s->memory, (void*)inputs[i], input_lens[i],
        in_dims + (size_t)i * DAL_ORT_MAX_RANK, (size_t)in_ranks[i],
        onnx_type(in_elements[i]), &in_values[i]);
    if (check(api, st, errbuf, errbuf_len, "CreateTensorWithDataAsOrtValue(input)")) {
      rc = 3; goto done;
    }
  }
  // Wrapping the caller's memory is what makes this a binding rather than a
  // copy: ORT writes the result through these pointers.
  for (int i = 0; i < num_outputs; i++) {
    OrtStatus* st = api->CreateTensorWithDataAsOrtValue(
        s->memory, outputs[i], output_lens[i],
        out_dims + (size_t)i * DAL_ORT_MAX_RANK, (size_t)out_ranks[i],
        onnx_type(out_elements[i]), &out_values[i]);
    if (check(api, st, errbuf, errbuf_len, "CreateTensorWithDataAsOrtValue(output)")) {
      rc = 4; goto done;
    }
  }

  OrtStatus* st = api->Run(s->session, NULL,
                           (const char* const*)s->input_names,
                           (const OrtValue* const*)in_values, (size_t)num_inputs,
                           (const char* const*)s->output_names, (size_t)num_outputs,
                           out_values);
  if (check(api, st, errbuf, errbuf_len, "Run")) { rc = 5; goto done; }

done:
  for (int i = 0; i < num_inputs; i++)
    if (in_values[i]) api->ReleaseValue(in_values[i]);
  for (int i = 0; i < num_outputs; i++)
    if (out_values[i]) api->ReleaseValue(out_values[i]);
  free(in_values);
  free(out_values);
  return rc;
}

int dal_ort_output_element_type(const DalOrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_outputs) ? s->out_element[i] : 0;
}
int dal_ort_output_rank(const DalOrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_outputs) ? s->out_rank[i] : 0;
}
void dal_ort_output_dims(const DalOrtSession* s, int i, int64_t* dims_out) {
  if (!s || i < 0 || i >= s->num_outputs || !dims_out) return;
  for (int d = 0; d < s->out_rank[i]; d++)
    dims_out[d] = s->out_dims[(size_t)i * DAL_ORT_MAX_RANK + d];
}
size_t dal_ort_output_byte_size(const DalOrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_outputs) ? s->out_bytes[i] : 0;
}
const void* dal_ort_output_data(const DalOrtSession* s, int i) {
  return (s && i >= 0 && i < s->num_outputs) ? s->out_copy[i] : NULL;
}
