// CLiteRt: a thin C shim over the LiteRT (formerly TensorFlow Lite) C API, so
// Swift can drive on-device inference without touching LiteRT's C bit-field
// structs (which Swift cannot access) or its multi-step tensor-buffer dance.
//
// The shim owns one compiled model plus its fixed-shape input/output host
// buffers, and exposes a tiny name/run/read surface that `LiteRTSession` (in the
// Inference module) marshals `Tensor`s through. All of LiteRT's intricate
// lifecycle (environment, model, options, compiled model, tensor buffer
// requirements, lock/unlock) stays here in C.
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

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DalLrtSession DalLrtSession;

// Create a session from a model file or from in-memory model bytes (pass one;
// the other NULL/0). On failure returns NULL and, if errbuf is non-NULL, writes
// a message. `accelerator` is a LiteRtHwAccelerators bitset (1 = CPU).
DalLrtSession* dal_lrt_create(const char* path, const void* data, size_t data_len,
                              int accelerator, char* errbuf, int errbuf_len);
void dal_lrt_free(DalLrtSession* session);

int dal_lrt_num_inputs(const DalLrtSession* session);
int dal_lrt_num_outputs(const DalLrtSession* session);
const char* dal_lrt_input_name(const DalLrtSession* session, int index);
const char* dal_lrt_output_name(const DalLrtSession* session, int index);

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
