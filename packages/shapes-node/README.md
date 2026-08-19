# @desert-ant-labs/shapes

On-device single-stroke shape recognition for JavaScript that runs in the browser and in Node. Give Shapes one hand-drawn stroke and it returns a clean vector shape: a line, rectangle, triangle, ellipse, or star. Strokes stay local.

A small classifier proposes a shape, a geometric fitter produces the clean parameters, and the stroke is accepted only if it clears that class's calibrated confidence and residual gates. The result snaps to nice axes, circles, squares, and 15 degree rotations.

Two entries share one `Shapes` API:

- **`@desert-ant-labs/shapes`** (default): a WebAssembly pipeline with [LiteRT.js](https://www.npmjs.com/package/@litertjs/core) inference, for the **browser**. It has no native dependencies, so a single import builds cleanly for every target of a multi-target bundler (Next.js, Remix, SvelteKit, Nuxt), including the browser bundle and the Client-Component SSR pass those frameworks render in Node. It is safe to *import* during server-side rendering, but LiteRT.js needs a browser (or Web Worker) to initialize, so `Shapes.load()` runs inference only in the browser; calling it in plain Node throws an actionable error pointing you to `/native`.
- **`@desert-ant-labs/shapes/native`**: a prebuilt native core, Core ML on macOS and LiteRT on Linux, for **server-side inference** in Node. No `@litertjs/core`, no build tools, no flags. Import it from server-only code (API routes, server actions, plain Node scripts). Do not import it from a component that also renders in the browser.

```bash
# Browser (default entry):
npm i @desert-ant-labs/shapes @litertjs/core

# Server-side inference in Node (/native entry) needs no extra install:
npm i @desert-ant-labs/shapes
```

The model is downloaded from the Hugging Face Hub on first use at the SDK's pinned tag, then cached. Nothing model-sized is shipped in the npm tarball.

```js
import { Shapes } from "@desert-ant-labs/shapes";

const shapes = await Shapes.load();
const shape = await shapes.recognize(points);   // [{x, y}, ...] or [x0, y0, ...]
// { kind: "ellipse", center: {x, y}, semiMajor, semiMinor, rotation }

shapes.dispose(); // release the model (both builds)
```

Server-only code that wants the native core imports the same API from the
`/native` subpath:

```js
import { Shapes } from "@desert-ant-labs/shapes/native"; // server only
```

## Shapes

`recognize` returns `null` when the stroke is rejected or degenerate, otherwise one of these, discriminated by `kind`:

- `line` - `from`, `to`
- `rectangle` - `corners`, four points around the perimeter
- `triangle` - `vertices`, three points
- `ellipse` - `center`, `semiMajor`, `semiMinor`, `rotation` (radians)
- `star` - `center`, `outerRadius`, `innerRadius`, `rotation` (radians), `pointCount`

The kinds and field names are identical in Swift and Kotlin, so a stroke recognized on one platform describes itself the same way on every other.

`recognize(points, { minimumConfidence })` raises the classifier threshold on top of each class's calibrated gate; the default `0` applies only the model's own gates.

## Loading the model

By default `Shapes.load()` downloads the model files from the Hugging Face Hub ([`desert-ant-labs/shapes`](https://huggingface.co/desert-ant-labs/shapes)) at the SDK's pinned tag, verifies them, and caches them. The browser build fetches the `.tflite` for LiteRT.js and caches it in the browser. The native build (`/native`) fetches the `.tflite` on Linux or the `.mlmodelc/` on macOS and caches it under the OS cache dir.

To self-host or run fully offline, opt out of the Hub:

- `directory`: an explicit model directory (native build, or the browser build under Node). Files already there are used offline, otherwise the model is downloaded into it.
- `modelBaseUrl`: a base URL you serve the model files from, for example `"/assets/shapes/"` (browser build).

`Shapes.load()` also accepts:

- `cacheRoot`: base directory for the managed on-disk cache, default `~/.cache` (native build, or the browser build under Node).
- `onProgress`: load or download progress callback, fraction in `[0, 1]`.

Browser-build-only options:

- `litert`: a bring-your-own `@litertjs/core` module.
- `litertWasmDir`: URL or path to the LiteRT.js Wasm directory.
- `accelerator`: one of `"wasm"`, `"webgpu"`, or `"webnn"`.

## Bundlers and SSR

The default `@desert-ant-labs/shapes` import is safe to use directly in components:
it is pure JavaScript + WebAssembly with no native modules, so bundlers can build
it for the browser and for the Node SSR pass from the same module graph with no
configuration.

The `@desert-ant-labs/shapes/native` subpath loads a native addon (via `koffi`) and
is for server-only code. If you import it inside a framework that bundles server
code (for example a Next.js Route Handler or Server Action), mark it external so
the bundler does not try to bundle the native binary. In Next.js:

```js
// next.config.js
module.exports = { serverExternalPackages: ["@desert-ant-labs/shapes"] };
```

## Platforms

The native server build (`/native`) ships for linux-x64, linux-arm64, and darwin-arm64. Other Node platforms throw a clear error at `load()`; use the default WebAssembly build, the Swift package, or a browser for those.

## License

[Desert Ant Labs Source-Available License 1.0](./LICENSE.md): free below 100,000 monthly active devices per platform. Above that a commercial license is required. Full terms: https://license.desertant.com/1.0
