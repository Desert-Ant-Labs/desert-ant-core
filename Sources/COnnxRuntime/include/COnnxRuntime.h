// COnnxRuntime: a thin C shim over the ONNX Runtime C API, so Swift can drive
// on-device inference without reaching through ORT's function-pointer API table
// or its OrtStatus error protocol, neither of which Swift imports usefully.
//
// The shim owns one session plus its output buffers and exposes the same
// name/run/read surface `CLiteRt` does, so `OnnxSession` is the same shape as
// `LiteRTSession`. ORT's lifecycle (api table, environment, session options,
// execution provider selection, OrtValue construction, status checking) stays
// here in C.
//
// Unlike the LiteRT shim, input shapes are supplied per run rather than read
// once from the model: Voz's encoder declares a dynamic batch axis so a partial
// group of windows costs only what it holds, and a fixed-shape session would
// throw that away.
//
// Element type codes match CLiteRt so the two backends need one mapping in
// Swift: 1 = float32, 2 = int32, 4 = int64.
#ifndef DAL_CONNXRUNTIME_H_
#define DAL_CONNXRUNTIME_H_

#include <stddef.h>
#include <stdint.h>

#include "onnxruntime/onnxruntime_c_api.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DalOrtSession DalOrtSession;

// Accelerator bitset, mirroring CLiteRt's so callers use one vocabulary:
// 1 = CPU, 2 = GPU, 4 = NPU. Requesting either accelerator is always safe: the
// shim adds the provider when the platform has it and otherwise builds a CPU
// session, because an execution provider claims whatever subgraphs it can and
// leaves the rest on CPU anyway.
//
// On Windows the GPU is DirectML, and on this hardware it is the one worth
// asking for: Voz runs end to end at 366x real time on a Radeon 8060S against
// 38.7x on the CPU provider, same float16 weights, character-identical
// transcript. The NPU is kept because the capability is real and cheap to
// offer, but it is not the fast path: it needs int8 weights, refuses the
// encoder's attention entirely, and at its best measured no faster than CPU.
#define DAL_ORT_CPU 1
#define DAL_ORT_GPU 2
#define DAL_ORT_NPU 4

// Build a session for the model at `path`. Returns NULL on failure, with a
// message in `errbuf`.
//
// `npu_ep_library` is the NPU execution provider's DLL, needed only when
// `accelerator` asks for the NPU. It has to be passed in rather than discovered
// here: the Windows ML providers live under C:\Program Files\WindowsApps, whose
// ACL denies a directory listing even though a known full path opens fine, so
// no glob finds them. NULL falls back to the `DAL_ORT_NPU_EP` environment
// variable, and failing that the session is built on CPU.
DalOrtSession* dal_ort_create(const char* path, int accelerator,
                              const char* npu_ep_library,
                              char* errbuf, int errbuf_len);
void dal_ort_free(DalOrtSession* s);

int dal_ort_num_inputs(const DalOrtSession* s);
int dal_ort_num_outputs(const DalOrtSession* s);
const char* dal_ort_input_name(const DalOrtSession* s, int i);
const char* dal_ort_output_name(const DalOrtSession* s, int i);

// Which accelerators were actually added to this session, as the same bitset.
// It says a provider is present, NOT that it claimed any node: an execution
// provider that takes nothing still appears on the session, so this is a
// capability probe and never evidence of where the graph ran. Proving placement
// needs a profile.
int dal_ort_accelerators(const DalOrtSession* s);

// Run once. Inputs arrive in the model's declared input order, each with its
// own shape: `dims` is flattened at `DAL_ORT_MAX_RANK` entries per input and
// `ranks[i]` says how many of them are real.
#define DAL_ORT_MAX_RANK 8
int dal_ort_run(DalOrtSession* s,
                const void* const* inputs, const size_t* input_lens,
                const int64_t* dims, const int32_t* ranks,
                const int32_t* elements, int num_inputs,
                char* errbuf, int errbuf_len);

// Run once, writing the outputs straight into caller memory instead of into
// buffers this shim owns.
//
// The ONNX Runtime equivalent of Core ML's `outputBackings`, and it exists for
// the same reason: Voz's decode step returns a [lanes, 8198, 1, width] logits
// tensor, which is a megabyte a dispatch at float32, and the decode loop
// dispatches hundreds of times a minute of audio. Copying that through an
// intermediate would cost more than the run.
//
// `outputs` is in the model's declared output order. Shapes travel exactly as
// the input ones do, and a caller that gets one wrong gets an error rather than
// a short write.
int dal_ort_run_bound(DalOrtSession* s,
                      const void* const* inputs, const size_t* input_lens,
                      const int64_t* in_dims, const int32_t* in_ranks,
                      const int32_t* in_elements, int num_inputs,
                      void* const* outputs, const size_t* output_lens,
                      const int64_t* out_dims, const int32_t* out_ranks,
                      const int32_t* out_elements, int num_outputs,
                      char* errbuf, int errbuf_len);

// Output metadata, valid after a successful run.
int dal_ort_output_element_type(const DalOrtSession* s, int i);
int dal_ort_output_rank(const DalOrtSession* s, int i);
void dal_ort_output_dims(const DalOrtSession* s, int i, int64_t* dims_out);
size_t dal_ort_output_byte_size(const DalOrtSession* s, int i);
const void* dal_ort_output_data(const DalOrtSession* s, int i);

#ifdef __cplusplus
}
#endif

#endif  // DAL_CONNXRUNTIME_H_
