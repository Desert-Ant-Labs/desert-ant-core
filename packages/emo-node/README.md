# @desert-ant-labs/emo

On-device multilingual emoji suggestions for JavaScript that run in the browser and in Node. Give Emo a short task, calendar entry, note, or message and it returns ranked emoji across 23 languages. Text stays local.

Two entries share one `Emo` API:

- **`@desert-ant-labs/emo`** (default): a WebAssembly pipeline with [LiteRT.js](https://www.npmjs.com/package/@litertjs/core) inference, for the **browser**. It has no native dependencies, so a single import builds cleanly for every target of a multi-target bundler (Next.js, Remix, SvelteKit, Nuxt), including the browser bundle and the Client-Component SSR pass those frameworks render in Node. It is safe to *import* during server-side rendering, but LiteRT.js needs a browser (or Web Worker) to initialize, so `Emo.load()` runs inference only in the browser; calling it in plain Node throws an actionable error pointing you to `/native`.
- **`@desert-ant-labs/emo/native`**: a prebuilt native core, Core ML on macOS and LiteRT on Linux, for **server-side inference** in Node. No `@litertjs/core`, no build tools, no flags. Import it from server-only code (API routes, server actions, plain Node scripts). Do not import it from a component that also renders in the browser.

```bash
# Browser (default entry):
npm i @desert-ant-labs/emo @litertjs/core

# Server-side inference in Node (/native entry) needs no extra install:
npm i @desert-ant-labs/emo
```

The model is downloaded from the Hugging Face Hub on first use at the SDK's pinned tag, then cached. Nothing model-sized is shipped in the npm tarball.

```js
import { Emo } from "@desert-ant-labs/emo";

const emo = await Emo.load();
const suggestions = await emo.suggestions("Pay my bills", { limit: 3 });
// [{ emoji: "💰", confidence: 0.65 }, ...]

emo.dispose(); // frees native resources in the /native build; no-op otherwise
```

Server-only code that wants the native core imports the same API from the
`/native` subpath:

```js
import { Emo } from "@desert-ant-labs/emo/native"; // server only
```

## Loading the model

By default `Emo.load()` downloads the model files from the Hugging Face Hub ([`desert-ant-labs/emo`](https://huggingface.co/desert-ant-labs/emo)) at the SDK's pinned tag, verifies them, and caches them. The browser build fetches the `.tflite` for LiteRT.js and caches it in the browser. The native build (`/native`) fetches the `.tflite` on Linux or the `.mlmodelc/` on macOS and caches it under the OS cache dir.

To self-host or run fully offline, opt out of the Hub:

- `directory`: an explicit model directory (native build, or the browser build under Node). Files already there are used offline, otherwise the model is downloaded into it.
- `modelBaseUrl`: a base URL you serve the model files from, for example `"/assets/emo/"` (browser build).

`Emo.load()` also accepts:

- `cacheRoot`: base directory for the managed on-disk cache, default `~/.cache` (native build, or the browser build under Node).
- `onProgress`: load or download progress callback, fraction in `[0, 1]`.
- `skinTone`: one of `"default"`, `"light"`, `"mediumLight"`, `"medium"`, `"mediumDark"`, or `"dark"` when calling `suggestions`.

Browser-build-only options:

- `litert`: a bring-your-own `@litertjs/core` module.
- `litertWasmDir`: URL or path to the LiteRT.js Wasm directory.
- `accelerator`: one of `"wasm"`, `"webgpu"`, or `"webnn"`.

## Bundlers and SSR

The default `@desert-ant-labs/emo` import is safe to use directly in components:
it is pure JavaScript + WebAssembly with no native modules, so bundlers can build
it for the browser and for the Node SSR pass from the same module graph with no
configuration.

The `@desert-ant-labs/emo/native` subpath loads a native addon (via `koffi`) and
is for server-only code. If you import it inside a framework that bundles server
code (for example a Next.js Route Handler or Server Action), mark it external so
the bundler does not try to bundle the native binary. In Next.js:

```js
// next.config.js
module.exports = { serverExternalPackages: ["@desert-ant-labs/emo"] };
```

## Platforms

The native server build (`/native`) ships for linux-x64, linux-arm64, and darwin-arm64. Other Node platforms throw a clear error at `load()`; use the default WebAssembly build, the Swift package, or a browser for those.

## License

[Desert Ant Labs Source-Available License 1.0](./LICENSE.md): free below 100,000 monthly active devices per platform. Above that a commercial license is required. Full terms: https://license.desertant.com/1.0
