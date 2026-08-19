# @desert-ant-labs/gist

On-device content topic tagging for JavaScript that runs in the browser and in Node. Give Gist a title (or a title plus description) and it returns multi-label topics from a fixed 36-topic taxonomy across 101 languages. Text stays local.

Two entries share one `Gist` API:

- **`@desert-ant-labs/gist`** (default): a WebAssembly pipeline with [LiteRT.js](https://www.npmjs.com/package/@litertjs/core) inference, for the **browser**. It has no native dependencies, so a single import builds cleanly for every target of a multi-target bundler (Next.js, Remix, SvelteKit, Nuxt), including the browser bundle and the Client-Component SSR pass those frameworks render in Node. It is safe to *import* during server-side rendering, but LiteRT.js needs a browser (or Web Worker) to initialize, so `Gist.load()` runs inference only in the browser; calling it in plain Node throws an actionable error pointing you to `/native`.
- **`@desert-ant-labs/gist/native`**: a prebuilt native core, Core ML on macOS and LiteRT on Linux, for **server-side inference** in Node. No `@litertjs/core`, no build tools, no flags. Import it from server-only code (API routes, server actions, plain Node scripts). Do not import it from a component that also renders in the browser.

```bash
# Browser (default entry):
npm i @desert-ant-labs/gist @litertjs/core

# Server-side inference in Node (/native entry) needs no extra install:
npm i @desert-ant-labs/gist
```

The model is downloaded from the Hugging Face Hub on first use at the SDK's pinned tag, then cached. Nothing model-sized is shipped in the npm tarball.

```js
import { Gist } from "@desert-ant-labs/gist";

const gist = await Gist.load();
const topics = await gist.classify("How to start a podcast with just your iPhone");
// [{ slug: "technology", name: "Technology & Software", score: 0.93 }, ...]

gist.dispose(); // release the model (both builds)
```

Server-only code that wants the native core imports the same API from the
`/native` subpath:

```js
import { Gist } from "@desert-ant-labs/gist/native"; // server only
```

## Scores and channel roll-up

`classify()` ranks and thresholds for you. `scores()` returns the whole
distribution instead, which is what you feed to the channel roll-up — a pure,
deterministic function with no model in it:

```js
import { Gist, channelTopics } from "@desert-ant-labs/gist";

const gist = await Gist.load();
const posts = [];
for (const title of titles) {
  posts.push({ topics: await gist.scores(title), timestampMillis: Date.now() });
}

channelTopics(posts, { topN: 5 });
// [{ slug: "technology", share: 0.41, postCount: 12 }, ...]
```

`channelTopics` takes `topN`, `floor`, `minPosts`, `halfLifeDays`, `touch`, and
`nowMillis`. Recency decay is off until you pass **both** `halfLifeDays` and
`nowMillis`, matching the Swift SDK.

## Loading the model

By default `Gist.load()` downloads the model files from the Hugging Face Hub ([`desert-ant-labs/gist`](https://huggingface.co/desert-ant-labs/gist)) at the SDK's pinned tag, verifies them, and caches them. The browser build fetches the `.tflite` for LiteRT.js and caches it in the browser. The native build (`/native`) fetches the `.tflite` on Linux or the `.mlmodelc/` on macOS and caches it under the OS cache dir.

To self-host or run fully offline, opt out of the Hub:

- `directory`: an explicit model directory (native build, or the browser build under Node). Files already there are used offline, otherwise the model is downloaded into it.
- `modelBaseUrl`: a base URL you serve the model files from, for example `"/assets/gist/"` (browser build).

`Gist.load()` also accepts:

- `cacheRoot`: base directory for the managed on-disk cache, default `~/.cache` (native build, or the browser build under Node).
- `onProgress`: load or download progress callback, fraction in `[0, 1]`.

`classify()` accepts `topK` (default 3) and `threshold` (defaults to the model's tuned one).

Browser-build-only options:

- `litert`: a bring-your-own `@litertjs/core` module.
- `litertWasmDir`: URL or path to the LiteRT.js Wasm directory.
- `accelerator`: one of `"wasm"`, `"webgpu"`, or `"webnn"`.

The English-only build (~15 MB, English/Latin text only) is currently selectable from the Swift SDK only.

## Bundlers and SSR

The default `@desert-ant-labs/gist` import is safe to use directly in components:
it is pure JavaScript + WebAssembly with no native modules, so bundlers can build
it for the browser and for the Node SSR pass from the same module graph with no
configuration.

The `@desert-ant-labs/gist/native` subpath loads a native addon (via `koffi`) and
is for server-only code. If you import it inside a framework that bundles server
code (for example a Next.js Route Handler or Server Action), mark it external so
the bundler does not try to bundle the native binary. In Next.js:

```js
// next.config.js
module.exports = { serverExternalPackages: ["@desert-ant-labs/gist"] };
```

## Platforms

The native server build (`/native`) ships for linux-x64, linux-arm64, and darwin-arm64. Other Node platforms throw a clear error at `load()`; use the default WebAssembly build, the Swift package, or a browser for those.

## License

[Desert Ant Labs Source-Available License 1.0](./LICENSE.md): free below 100,000 monthly active devices per platform. Above that a commercial license is required. Full terms: https://license.desertant.com/1.0
