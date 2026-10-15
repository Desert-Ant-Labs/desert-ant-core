// CLiteRt: a thin C shim over the LiteRT (formerly TensorFlow Lite) C API, so
// Swift can drive on-device inference without touching LiteRT's C bit-field
// structs (which Swift cannot access) or its multi-step tensor-buffer dance.
//
// A model (`DalLrtModel`) is one compiled `.tflite`; a session (`DalLrtSession`)
// is one of its signatures with that signature's fixed-shape input/output
// buffers, exposing a tiny name/run/read surface that `LiteRTSession` (in the
// Inference module) marshals `Tensor`s through. A model with several signatures
// is compiled once and shared by their sessions, so its weights are loaded and
// packed once. All of LiteRT's intricate lifecycle (environment, model, options,
// compiled model, tensor buffer requirements, lock/unlock) stays here in C. The
// environment is one per process, shared by every model (see shim.c for why),
// except on Android when the GPU is requested: then the model carries a private
// environment holding its own EGL context, which LiteRT's GL backend needs to
// allocate and map tensor buffers.
//
// Sessions of one model share its compiled model, which LiteRT does not run
// reentrantly: the caller serializes runs across a model's sessions.
//
// Element type codes match LiteRtElementType: 1 = float32, 2 = int32, 4 = int64.
#ifndef DAL_CLITERT_H_
#define DAL_CLITERT_H_

#include <stddef.h>
#include <stdint.h>

#include "litert/c/litert_common.h"
#include "litert/c/litert_compiled_model.h"
#include "litert/c/litert_environment.h"
#include "litert/c/litert_model.h"
#include "litert/c/litert_options.h"
#include "litert/c/litert_tensor_buffer.h"
#include "litert/c/litert_tensor_buffer_requirements.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DalLrtModel DalLrtModel;
typedef struct DalLrtSession DalLrtSession;

// Compile a model from a file or from in-memory model bytes (pass one; the other
// NULL/0). On failure returns NULL and, if errbuf is non-NULL, writes a message.
// `accelerator` is a LiteRtHwAccelerators bitset (1 = CPU, 2 = GPU, 4 = NPU).
// `num_threads` sets the CPU (XNNPACK) thread count; 0 picks a heuristic (half
// the online cores, DAL_LITERT_THREADS overrides). Pass 1 for graphs dispatched
// per step, where a thread pool costs more in synchronization than it computes.
// `gpu_precision` is a LiteRtDelegatePrecision (0 default, 1 fp16, 2 fp32,
// 3 fp16 with fp32 accumulation) applied when the GPU is requested. The caller
// holds one reference; every session made from it holds another.
DalLrtModel* dal_lrt_model_create(const char* path, const void* data, size_t data_len,
                                  int accelerator, int num_threads, int gpu_precision,
                                  char* errbuf, int errbuf_len);
// Drop the caller's reference. The model is freed with its last session.
void dal_lrt_model_release(DalLrtModel* model);
int dal_lrt_model_num_signatures(const DalLrtModel* model);
const char* dal_lrt_model_signature_key(const DalLrtModel* model, int index);

// A session over one signature, by key (NULL: the first signature).
DalLrtSession* dal_lrt_session_create(DalLrtModel* model, const char* signature,
                                      char* errbuf, int errbuf_len);

// Model and session in one: the first signature of a model nothing else shares.
DalLrtSession* dal_lrt_create(const char* path, const void* data, size_t data_len,
                              int accelerator, int num_threads, int gpu_precision,
                              char* errbuf, int errbuf_len);
void dal_lrt_free(DalLrtSession* session);

int dal_lrt_num_inputs(const DalLrtSession* session);
int dal_lrt_num_outputs(const DalLrtSession* session);
const char* dal_lrt_input_name(const DalLrtSession* session, int index);
const char* dal_lrt_output_name(const DalLrtSession* session, int index);

// Input metadata (fixed shapes), valid from creation: element type code, rank,
// and dimensions, so a caller can size its buffers from the artifact rather
// than from a constant.
int dal_lrt_input_element_type(const DalLrtSession* session, int index);
int dal_lrt_input_rank(const DalLrtSession* session, int index);
void dal_lrt_input_dims(const DalLrtSession* session, int index, int32_t* dims_out);

// Run once. `inputs`/`input_lens` are arrays of length num_inputs, in the model's
// input order (host byte order, matching each input's element type and shape).
// Returns 0 on success, non-zero on error (message in errbuf).
int dal_lrt_run(DalLrtSession* session, const void* const* inputs,
                const size_t* input_lens, int num_inputs, char* errbuf, int errbuf_len);

// Output accessors, valid after a successful run until the next run or free.
int dal_lrt_output_element_type(const DalLrtSession* session, int index);
int dal_lrt_output_rank(const DalLrtSession* session, int index);
void dal_lrt_output_dims(const DalLrtSession* session, int index, int32_t* dims_out);
size_t dal_lrt_output_byte_size(const DalLrtSession* session, int index);
const void* dal_lrt_output_data(const DalLrtSession* session, int index);

#ifdef __cplusplus
}
#endif

#endif  // DAL_CLITERT_H_
