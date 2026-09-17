# Voz on the Pixel TPU: what we tried, what we learned, how to retry

This directory is the record and the tooling for getting Voz's decoder onto the
Google Tensor NPU (the EdgeTPU / "DarwiNN" accelerator in Pixel phones). Nothing
here is wired into a shipping build; it is what a session picks up to continue.

The encoder is happy on the GPU (OpenCL, fp32, ~0.39 s per 15 s window, 20x
realtime warm). The decoder is the remaining target: int8, tiny, dispatched a
few hundred times per transcription, which is the dispatch-latency shape an NPU
serves best.

## Two doors to the same TPU, one open

**1. LiteRT's own NPU path (dispatch library + compiler plugin).** LiteRT's
`kLiteRtHwAcceleratorNpu` resolves a vendor dispatch library, and for
just-in-time compilation a compiler plugin, from a directory the caller names.
Those libraries do not exist on Maven for Google Tensor, so
`build-google-tensor-libs.sh` builds them from the LiteRT source tree with the
NDK. They build, load, and run the on-device EdgeTPU compiler - and then the
compile is refused:

    edgetpu_app_service: <pkg> is not in the EdgeTPU allowed list or signature
      mismatched. Please add the app to the edgetpu allowlist.
    Compile failed, error code 16: Current application should not be allowed to
      access EdgeTPU.

That is a per-package allowlist inside a Google-signed system service. No code
of ours satisfies it; it needs Google (LiteRT NPU early access, or an allowlist
entry). The shim plumbing for this path is in `Sources/CLiteRt/shim.c`
(`DAL_NPU_LIBRARY_DIR` -> `DispatchLibraryDir` + `CompilerPluginLibraryDir`).

**2. NNAPI (the classic TFLite delegate).** The same TPU is also an NNAPI
device, `android.hardware.neuralnetworks/google-edgetpu`, reached through the
system NN runtime rather than that app service. A plain `shell` process
enumerates it and `createForDevices` succeeds with **no allowlist refusal**.
This is the open door.

What stops NNAPI today is the model, not permission. The DarwiNN NNAPI driver
refuses our decoder's ops because their I/O tensors are `TENSOR_FLOAT32`:

    darwinn_mlir_converter_aidl.cc: RET_CHECK failed:
      input.type != aidl_hal::OperandType::TENSOR_FLOAT32
    Found a subgraph of size = 47, that would be delegated to CPU.

Our "int8" decoder is weight-quantized with float activations. The TPU wants a
fully-integer graph, int8 activations and int8 graph I/O. That is an export
change in `../voz-training` (a static/full-integer quantization of the decode
step, I/O forced to int8), not a change here.

## The probes

Build with the NDK (`aarch64-linux-android31-clang`), push to
`/data/local/tmp`, run from there.

- **`nnprobe.c`** - pure NNAPI, links `libneuralnetworks`. Enumerates NN devices
  and tries to compile a one-op model *for the edgetpu device*. Answers "is the
  NN HAL gated?" (it is not). Build:
      $CC nnprobe.c -o nnprobe -lneuralnetworks -landroid

- **`decprobe.c`** - routes a real `.tflite` through the classic TFLite
  interpreter with `SetUseNNAPI(1)`, dlopen'ing the shipped `libLiteRt.so` (which
  exports the classic TFLite C API). The verdict is one logcat line: the DarwiNN
  driver either claims a subgraph or reports "delegated to CPU". Build:
      $CC decprobe.c -o decprobe -ldl
  Run (needs libLiteRt.so and a decoder.tflite alongside it):
      adb push decprobe libLiteRt.so decoder.tflite /data/local/tmp/
      adb shell 'cd /data/local/tmp && LD_LIBRARY_PATH=. ./decprobe'
      adb logcat -d | grep -iE 'nnapi|edgetpu|delegated|Replacing'

This is the fast loop for a new export: push the new `decoder.tflite`, rerun
`decprobe`, read the one line. No app rebuild, no allowlist, no GPU. When the
line stops saying "delegated to CPU" and the driver claims the ops, the export
fits the TPU and it is worth wiring `kLiteRtHwAcceleratorNpu` (or a direct NNAPI
delegate) into the decode session and measuring.

## The vendor-library build

`build-google-tensor-libs.sh` produces the two Google Tensor libraries for the
LiteRT NPU path (door 1). It pins to the LiteRT tag matching `Vendor/litert`
(the dispatch library and `libLiteRt.so` share an internal ABI; a mismatch
aborts at delegate init). The two `*.pb.h` files are hand-rolled proto3 wire
encoders standing in for protoc output, so the build needs no libprotobuf; if a
future LiteRT tag changes `google_tensor_options.proto` or
`edgetpu_compiler_options.proto`, diff the `.proto` between tags and update the
field numbers in the stand-ins. This path is blocked on the allowlist above and
is kept only because it is the only public way to produce these libraries.
