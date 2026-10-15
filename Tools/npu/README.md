# Voz on the Pixel TPU: what we tried, what we learned, how to retry

This directory is the record and the tooling for getting Voz's decoder onto the
Google Tensor NPU (the EdgeTPU / "DarwiNN" accelerator in Pixel phones). Nothing
here is wired into a shipping build; it is what a session picks up to continue.

The encoder is happy on the GPU (OpenCL, fp32, ~0.39 s per 15 s window, 20x
realtime warm). The decoder is the remaining target: int8, tiny, dispatched a
few hundred times per transcription, which is the dispatch-latency shape an NPU
serves best.

## Where the attempt stopped

LiteRT's `kLiteRtHwAcceleratorNpu` resolves a vendor dispatch library, and for
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
entry). The shim no longer carries plumbing for this path; wiring it back in
means handing `DispatchLibraryDir` and `CompilerPluginLibraryDir` environment
options to `LiteRtCreateEnvironment` in `Sources/CLiteRt/shim.c`.

A separate probe of the TPU through the system NN runtime (since removed with
the rest of the NNAPI tooling) established two facts worth keeping: the TPU
itself is not permission-gated behind that runtime, and the DarwiNN driver
refuses our decoder because its activations and graph I/O are float32. The
export it wants is fully integer: int8 activations and int8 I/O. That is an
export change in `../voz-training` (a static/full-integer quantization of the
decode step), not a change here. Until such an export exists, no door matters.

## The vendor-library build

`build-google-tensor-libs.sh` produces the two Google Tensor libraries for the
LiteRT NPU path. It pins to the LiteRT tag matching `Vendor/litert` (the
dispatch library and `libLiteRt.so` share an internal ABI; a mismatch aborts at
delegate init). The two `*.pb.h` files are hand-rolled proto3 wire encoders
standing in for protoc output, so the build needs no libprotobuf; if a future
LiteRT tag changes `google_tensor_options.proto` or
`edgetpu_compiler_options.proto`, diff the `.proto` between tags and update the
field numbers in the stand-ins. This path is blocked on the allowlist above and
is kept only because it is the only public way to produce these libraries.
