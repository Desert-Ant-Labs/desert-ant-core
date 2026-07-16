#include "CLiteRt.h"

#include <stdlib.h>
#include <string.h>

// One compiled model with its fixed-shape input/output host buffers, created
// once and reused: each run writes inputs, invokes, and copies outputs out.

struct DalLrtSession {
  LiteRtEnvironment env;
  LiteRtModel model;
  LiteRtOptions options;
  LiteRtCompiledModel compiled;

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
    strncpy(errbuf, msg, (size_t)(len - 1));
    errbuf[len - 1] = '\0';
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
  if (s->compiled) LiteRtDestroyCompiledModel(s->compiled);
  if (s->options) LiteRtDestroyOptions(s->options);
  if (s->model) LiteRtDestroyModel(s->model);
  if (s->env) LiteRtDestroyEnvironment(s->env);
  free(s);
}

static char* copy_string(const char* s) {
  size_t n = strlen(s) + 1;
  char* out = (char*)malloc(n);
  if (out) memcpy(out, s, n);
  return out;
}

DalLrtSession* dal_lrt_create(const char* path, const void* data, size_t data_len,
                              int accelerator, char* errbuf, int errbuf_len) {
  DalLrtSession* s = (DalLrtSession*)calloc(1, sizeof(DalLrtSession));
  if (!s) { set_err(errbuf, errbuf_len, "out of memory"); return NULL; }

  if (LiteRtCreateEnvironment(0, NULL, &s->env) != kLiteRtStatusOk) {
    set_err(errbuf, errbuf_len, "LiteRtCreateEnvironment failed"); goto fail;
  }
  if (path) {
    if (LiteRtCreateModelFromFile(s->env, path, &s->model) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "LiteRtCreateModelFromFile failed"); goto fail;
    }
  } else if (data && data_len > 0) {
    if (LiteRtCreateModelFromBuffer(s->env, data, data_len, &s->model) != kLiteRtStatusOk) {
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
    if (LiteRtCreateOptions(&s->options) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "LiteRtCreateOptions failed"); goto fail;
    }
    LiteRtSetOptionsHardwareAccelerators(s->options, accel);
    compiled_status = LiteRtCreateCompiledModel(s->env, s->model, s->options, &s->compiled);
    if (compiled_status == kLiteRtStatusOk) break;
    // Failed: drop this attempt's options and, if we asked for more than CPU,
    // retry CPU-only once.
    LiteRtDestroyOptions(s->options); s->options = NULL;
    if (accel == kLiteRtHwAcceleratorCpu) break;
    accel = kLiteRtHwAcceleratorCpu;
  }
  if (compiled_status != kLiteRtStatusOk) {
    set_err(errbuf, errbuf_len, "LiteRtCreateCompiledModel failed"); goto fail;
  }

  // Names come from signature 0; tensor types from the main subgraph (index
  // aligned for our single-signature models).
  LiteRtSignature sig = NULL;
  if (LiteRtGetModelSignature(s->model, 0, &sig) != kLiteRtStatusOk) {
    set_err(errbuf, errbuf_len, "LiteRtGetModelSignature failed"); goto fail;
  }
  LiteRtSubgraph subgraph = NULL;
  if (LiteRtGetModelSubgraph(s->model, 0, &subgraph) != kLiteRtStatusOk) {
    set_err(errbuf, errbuf_len, "LiteRtGetModelSubgraph failed"); goto fail;
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
    if (LiteRtGetSubgraphInput(subgraph, (LiteRtParamIndex)i, &tensor) != kLiteRtStatusOk ||
        LiteRtGetRankedTensorType(tensor, &type) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "reading input tensor type failed"); goto fail;
    }
    LiteRtTensorBufferRequirements reqs = NULL;
    if (LiteRtGetCompiledModelInputBufferRequirements(s->compiled, 0, (LiteRtParamIndex)i, &reqs)
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
    if (LiteRtGetSubgraphOutput(subgraph, (LiteRtParamIndex)i, &tensor) != kLiteRtStatusOk ||
        LiteRtGetRankedTensorType(tensor, &type) != kLiteRtStatusOk) {
      set_err(errbuf, errbuf_len, "reading output tensor type failed"); goto fail;
    }
    s->out_element[i] = (int)type.element_type;
    s->out_rank[i] = (int)type.layout.rank;
    for (unsigned int d = 0; d < type.layout.rank && d < LITERT_TENSOR_MAX_RANK; d++)
      s->out_dims[i * LITERT_TENSOR_MAX_RANK + d] = type.layout.dimensions[d];
    s->out_bytes[i] = layout_bytes(&type);

    LiteRtTensorBufferRequirements reqs = NULL;
    if (LiteRtGetCompiledModelOutputBufferRequirements(s->compiled, 0, (LiteRtParamIndex)i, &reqs)
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
