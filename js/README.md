# @desert-ant-labs/core

Shared JavaScript runtime for [Desert Ant Labs](https://desertant.com) on-device
model SDKs. The per-model node packages (`@desert-ant-labs/shapes`,
`@desert-ant-labs/emo`, `@desert-ant-labs/redact`, ...) build their browser and
Node entries on these model-agnostic pieces, so each model ships only its payload
codecs and its public class - both entry points are a couple of lines of wiring.

Not meant to be used directly; it is the common core the model packages depend
on.

## What it provides

Browser-safe entry (`@desert-ant-labs/core`, no `node:*`):

- `createWasmSdk({ platform, packageName, modelId, hostGlobal, files })` - the
  whole browser/WebAssembly half of a model package: instantiate the core through
  the package's `#platform` seam, set up the LiteRT.js session, then
  `open(options)` either downloads the model from the Hub or adopts the files a
  `modelBaseUrl` serves, and returns a ready `LoadedModel`.
- `LoadedModel` - a loaded model behind an opaque core handle: `run(text,
  options, { group, deviceId })` returning an `FfiReader`, plus `isDownloaded`,
  `withCallGroup`, and `dispose`. The same object on both runtimes, so a package
  writes its public class once.
- `installLiteRtHost(...)` - installs the LiteRT.js host the wasm core drives
  through `globalThis[hostGlobal]`: named-tensor `createSession` / `run` with the
  correct dtype marshalling and LiteRT.js manual memory management.
- `loadLiteRt(...)` / `assertBrowserRuntime(...)` - load `@litertjs/core` once
  per process (with an install hint) and guard against running the wasm runtime
  in plain Node.
- `fetchSelfHostedModel(baseUrl, files)` - fetch the files a `modelBaseUrl`
  serves: sidecars keyed by catalog name, artifact bytes for the host to compile.
- `browserSetup` / `browserWasmDir` / `browserReadModelSource` /
  `browserCacheRoot` - the browser half of a model's `#platform` seam.
- `wasmExports(modelId)` - the model-agnostic WebAssembly ABI a Swift core
  installs on `globalThis.__DesertAntExports[modelId]` (`create`,
  `createSelfHosted`, `isDownloaded`, `download`, `run`, `endCallGroup`,
  `destroy`, `flushTelemetry`), the twin of the native `dal_*` symbols. Both
  setups return it, so a model package writes no wasm glue: options and results
  cross as FFIBuffer payloads it encodes with the codecs it already needs for
  the native entry.
- `FfiReader` / `FfiWriter` - big-endian cursor over the length-prefixed
  FFIBuffer payloads both cores speak (the JS counterpart of Kotlin's
  `FfiReader`).

Node entry (`@desert-ant-labs/core/node`, uses `node:*` + koffi):

- `createNativeSdk({ here, packageName, modelId })` - the native half of a model
  package, mirroring `createWasmSdk`: binds the prebuilt core and returns an SDK
  whose `open(options)` yields the same `LoadedModel`.
- `loadNative({ here, packageName, coreName, symbols })` - the loader under it:
  resolves the prebuilt Swift core under `native/<platform>-<arch>`, loads the
  LiteRT runtime first, binds the `dal_*` C ABI with koffi, and returns
  `callAsync` + `decodeResult` + cache-path helpers.
- `nodeSetup` / `nodeWasmDir` / `nodeReadModelSource` / `nodeCacheRoot` - the
  Node half of the `#platform` seam.

`@litertjs/core` and `koffi` are optional peer dependencies: the browser path
needs `@litertjs/core`, the native Node path needs `koffi`, and neither is
required just to import the package.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0).
