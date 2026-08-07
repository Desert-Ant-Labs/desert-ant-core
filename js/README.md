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
- The wasm ABI itself (`create`, `createSelfHosted`, `isDownloaded`, `download`,
  `run`, `endCallGroup`, `destroy`, `flushTelemetry`), the twin of the native
  `dal_*` symbols, is what BridgeJS generates from the `@JS` entry points in the
  model's `Web/main.swift`; its types live in the package's own generated
  `dist/bridge-js.d.ts`. Both setups return it, so a model package writes no wasm
  glue: options and results cross as FFIBuffer payloads it encodes with the
  codecs it already needs for the native entry.
- `FfiReader` / `FfiWriter` - big-endian cursor over the length-prefixed
  FFIBuffer payloads both cores speak (the JS counterpart of Kotlin's
  `FfiReader`).

Node entry (`@desert-ant-labs/core/node`, uses `node:*` + koffi):

- `createNativeSdk({ here, packageName, modelId, coreName })` - the native half of
  a model package, mirroring `createWasmSdk`: binds the prebuilt core and returns
  an SDK whose `open(options)` yields the same `LoadedModel`.
- `loadNative({ here, packageName, coreName, modelId })` - the loader under it:
  resolves the prebuilt Swift core under `native/<platform>-<arch>`, loads the
  LiteRT runtime first, binds the C ABI with koffi (generic `dal_*` calls plus
  the model's own `<modelId>_create`), and returns `callAsync` + `decodeResult` +
  cache-path helpers.
SSR-safe node seam (`@desert-ant-labs/core/platform-node`, uses `node:*`, no
koffi):

- `nodeSetup` / `nodeWasmDir` / `nodeReadModelSource` / `nodeCacheRoot` - the
  Node half of the `#platform` seam, reached when a framework renders the
  universal wasm entry in Node (Next.js's Client-Component SSR pass).

The two node entries stay apart on purpose. koffi ships native `.node` addons,
and bundlers statically trace the `require("koffi")` inside the loader even
though it only runs lazily, so a package's `#platform` seam importing
`/node` makes an SSR build fail with Turbopack's "non-ecmascript placeable
asset" (or webpack's equivalent). A model package imports `/node` from its
`/native` entry only, and `/platform-node` from `platform-node.js`.

Audio models use the separate `@desert-ant-labs/core/audio` browser entry or
`@desert-ant-labs/core/audio/node` on Node. Text-model imports never traverse
the audio host or WAV codec.

`@litertjs/core` and `koffi` are optional peer dependencies: the browser path
needs `@litertjs/core`, the native Node path needs `koffi`, and neither is
required just to import the package.

## Tests

```bash
mise run test:js        # unit tests + the SSR module-graph guard (no network)
mise run test:bundles   # the bundle matrix: real bundlers, real tarballs
```

The packages are isomorphic, so most of what can break lives in a bundler rather
than in a function. Two layers cover it:

- `test/ssr-graph.test.mjs` walks the static import graph the way a bundler does
  and fails if the browser or SSR seam reaches koffi or a `node:` builtin. Fast,
  offline, runs on every change.
- `test/bundle/` packs the core and every model package and builds them with
  esbuild, vite, webpack, and Next (Turbopack + webpack), plus plain Node imports
  of both entries. It reproduces consumer build failures exactly; see
  [js/test/bundle/README.md](test/bundle/README.md).

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0).
