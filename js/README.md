# @desert-ant-labs/core

Shared JavaScript runtime for [Desert Ant Labs](https://desertant.com) on-device
model SDKs. The per-model node packages (`@desert-ant-labs/shapes`,
`@desert-ant-labs/emo`, `@desert-ant-labs/redact`, ...) build their browser and
Node entries on these model-agnostic pieces, so each model ships only its own
decode + public API.

Not meant to be used directly; it is the common core the model packages depend
on.

## What it provides

Browser-safe entry (`@desert-ant-labs/core`, no `node:*`):

- `installLiteRtHost(...)` - installs the LiteRT.js host the wasm core drives
  through `globalThis[hostGlobal]`: named-tensor `createSession` / `run` with the
  correct dtype marshalling and LiteRT.js manual memory management.
- `loadLiteRt(...)` / `assertBrowserRuntime(...)` - load `@litertjs/core` once
  per process (with an install hint) and guard against running the wasm runtime
  in plain Node.
- `fetchModelFrom(baseUrl, files)` - the self-hosted (`modelBaseUrl`) opt-out.
- `browserSetup` / `browserWasmDir` / `browserReadModelSource` /
  `browserCacheRoot` - the browser half of a model's `#platform` seam.
- `FfiReader` - big-endian cursor over the length-prefixed FFIBuffer payload the
  native core returns (the JS counterpart of Kotlin's `FfiReader`).

Node entry (`@desert-ant-labs/core/node`, uses `node:*` + koffi):

- `loadNative({ here, packageName, coreName, symbols })` - resolves the prebuilt
  Swift core under `native/<platform>-<arch>`, loads the LiteRT runtime first,
  binds the model's C ABI with koffi, and returns `callAsync` + `decodeResult` +
  cache-path helpers.
- `nodeSetup` / `nodeWasmDir` / `nodeReadModelSource` / `nodeCacheRoot` - the
  Node half of the `#platform` seam.

`@litertjs/core` and `koffi` are optional peer dependencies: the browser path
needs `@litertjs/core`, the native Node path needs `koffi`, and neither is
required just to import the package.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0).
