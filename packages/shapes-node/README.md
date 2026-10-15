# @desert-ant-labs/shapes

Shapes turns a hand-drawn stroke into a clean shape, connector, or arrow, in the browser and in Node. Shapes recognizes 13 kinds: a straight or curved connector, an arrow, a rectangle, an ellipse, a triangle, a diamond, a pentagon, a hexagon, a star, a heart, a cloud, and a scribble, which your app can use as an erase gesture. For any other stroke, such as handwriting, `recognize` returns `null`, so you can keep that stroke as ink. The stroke never leaves the device.

A small model scores each kind and marks the points that belong to an arrowhead. A geometric fitter then computes the clean shape. Shapes accepts a stroke only if the model's confidence and the fit both clear that kind's calibrated thresholds. By default, Shapes snaps lines and edges to the axes, near-circles to circles, near-squares to squares, near-regular polygons to regular ones, and rotations to 15° steps.

Two entries share one `Shapes` API:

- **`@desert-ant-labs/shapes`** (default): a WebAssembly pipeline with [LiteRT.js](https://www.npmjs.com/package/@litertjs/core) inference, for the **browser**. It has no native dependencies, so a single import builds cleanly for every target of a multi-target bundler (Next.js, Remix, SvelteKit, Nuxt), including the browser bundle and the Client-Component SSR pass those frameworks render in Node. It is safe to *import* during server-side rendering, but LiteRT.js needs a browser (or Web Worker) to initialize, so `Shapes.load()` runs inference only in the browser; calling it in plain Node throws an actionable error pointing you to `/native`.
- **`@desert-ant-labs/shapes/native`**: a prebuilt native core, Core ML on macOS and LiteRT on Linux, for **server-side inference** in Node. No `@litertjs/core`, no build tools, no flags. Import it from server-only code (API routes, server actions, plain Node scripts). Do not import it from a component that also renders in the browser.

```bash
# Browser (default entry):
npm i @desert-ant-labs/shapes @litertjs/core

# Server-side inference in Node (/native entry) needs no extra install:
npm i @desert-ant-labs/shapes
```

The model is downloaded from Hugging Face on first use at the SDK's pinned tag, then cached. Nothing model-sized is shipped in the npm tarball.

```js
import { Shapes } from "@desert-ant-labs/shapes";

const shapes = await Shapes.load();
const shape = await shapes.recognize(points);   // [{x, y}, ...] or [x0, y0, ...]
// { kind: "ellipse", center: {x, y}, semiMajor, semiMinor, rotation, outline: [...] }

shapes.dispose(); // release the model (both builds)
```

Server-only code that wants the native core imports the same API from the
`/native` subpath:

```js
import { Shapes } from "@desert-ant-labs/shapes/native"; // server only
```

## Shapes

`recognize` returns `null` when the stroke isn't a shape. Otherwise `recognize` returns one of these objects, discriminated by `kind`. Every shape also has `outline`, a polyline you can draw. A closed shape's outline doesn't repeat its first point, and an arrow's outline is its shaft.

- `line` - `from`, `to`
- `curve` - `from`, `control1`, `control2`, `to` (a cubic Bezier)
- `arrow` - `from`, `control1`, `control2`, `to`, `startHead`, `endHead`. `arrowheads(shape, length)` returns the heads as `[barb, tip, barb]` polylines.
- `rectangle` - `corners`, four points around the perimeter
- `ellipse` - `center`, `semiMajor`, `semiMinor`, `rotation` (radians)
- `triangle`, `diamond`, `pentagon`, `hexagon` - `vertices`, around the perimeter
- `star` - `center`, `outerRadius`, `innerRadius`, `rotation` (radians, 0 puts a tip straight up), `pointCount`
- `heart` - `center`, `width`, `height`
- `cloud` - `outline` only
- `scribble` - `hull`, the convex hull of the scribble. Delete the content inside the hull.

The kinds and field names are identical in Swift and Kotlin, so a stroke recognized on one platform describes itself the same way on every other.

`recognize(points, options)` takes three options:

- `rotation`: `"snapped"` is the default. It rounds a shape's rotation to 15° steps and snaps lines and edges within 5° of horizontal or vertical onto the axis. `"upright"` removes rotation. `"free"` keeps the shape as drawn and skips the snapping to circles, squares, and regular polygons.
- `kinds`: the kinds Shapes recognizes, all 13 by default. Leave out `"scribble"` if your app has no erase gesture.
- `minimumConfidence`: the lowest classifier confidence Shapes accepts, on top of each kind's calibrated threshold. The default `0` applies only the calibrated thresholds.

## Loading the model

By default `Shapes.load()` downloads the model files from Hugging Face ([`desert-ant-labs/shapes`](https://huggingface.co/desert-ant-labs/shapes)) at the SDK's pinned tag, verifies them, and caches them. The browser build fetches the `.tflite` for LiteRT.js and caches it in the browser. The native build (`/native`) fetches the `.tflite` on Linux or the `.mlmodelc/` on macOS and caches it under the OS cache dir.

To self-host or run fully offline, skip the Hugging Face download:

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
