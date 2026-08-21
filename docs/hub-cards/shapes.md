---
license: other
license_name: desert-ant-labs-source-available-1.0
license_link: https://license.desertant.com/1.0
tags:
- strokes
- shapes
- sketches
- pen-input
- on-device
- core-ml
- litert
- tflite
- pencilkit
pipeline_tag: image-classification
---

# Shapes: on-device shape recognition from a single stroke

Takes a single hand-drawn stroke (an ordered list of points) and recognizes it as
a clean geometric shape, returning fitted vector geometry ready to snap to. Built
for PencilKit-style "smart shapes": draw, pause, and the rough stroke becomes a
crisp shape. The model is tiny (**about 0.2 MB** Core ML, **~1.3 MB** LiteRT) and
runs in a few milliseconds on device.

> ✏️ ➜ ▭  ·  ✏️ ➜ △  ·  ✏️ ➜ ◯  ·  ✏️ ➜ ★

## Try it

All platforms ship from one repo: **[Desert-Ant-Labs/shapes](https://github.com/Desert-Ant-Labs/shapes)** (Swift, Kotlin, and JavaScript in a single codebase).

- **Live demo:** [desert-ant-labs/shapes-demo](https://huggingface.co/spaces/desert-ant-labs/shapes-demo): draw one stroke, get a fitted shape, fully in your browser.
- **iOS / macOS / tvOS / visionOS:** the Swift SDK (Swift Package Manager) with a one-line `PKCanvasView.enableShapeSnapping()` and a demo app. It bundles the compiled Core ML model below.
- **Android / JVM (Kotlin):** Maven Central `ai.desertant:shapes` with LiteRT (`.tflite`). The small model is bundled by default; exclude `ai.desertant:shapes-tflite-resources` to force on-demand download or explicit-directory loading.
- **Node / browser (JavaScript / TypeScript):** `npm i @desert-ant-labs/shapes @litertjs/core` for browser builds, or just `npm i @desert-ant-labs/shapes` for server-side Node. The npm package downloads the model from this repo on first use and caches it (nothing model-sized ships in the tarball); browser inference uses [LiteRT.js](https://www.npmjs.com/package/@litertjs/core), and Node uses prebuilt native libraries. Pass `directory` (Node) or `modelBaseUrl` (browser) to self-host / run offline.

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `shapes.tflite` | LiteRT / TFLite (fp32) | ~1.3 MB | Fixed `[1,256,3]` features + `[1,256]` mask window; runs on Android, Linux, Node, and the web (bundled by default in the Kotlin SDK; downloaded on demand by the JavaScript SDK) |
| `shapes.mlmodelc` | Compiled Core ML | ~0.2 MB | 4-bit-palettized classifier, ready to load on Apple platforms (used by the Swift SDK) |
| `shapes_meta.json` | JSON | tiny | classes, preprocessing constants, model dims, and snap gates |
| `shapes.safetensors` | safetensors | ~0.2 MB | packed portable weights (reference) |
| `model.pt` | PyTorch checkpoint | ~1.5 MB | trained weights (for export / fine-tuning) |
| `config.json` | JSON | tiny | class list, preprocessing constants, and per-class snap gates |

Older revisions (tag `v0.1.0`) carry `shapes.onnx` for SDK versions that predate the LiteRT migration.

## How it works

Two stages, *the network proposes, geometry verifies*:

1. **Classify**: the stroke is resampled and fed to a compact sequence classifier
   (Conv1d stem → small Transformer encoder → masked mean-pool → MLP), which
   predicts the shape type (or `none` to reject scribbles).
2. **Fit + snap**: a classical geometric fitter produces clean vector parameters
   (min-area box, moment/PCA ellipse, max-area triangle, …), then regularizes them
   (snap to axes, circles, squares, and 15° rotation increments). A fit-residual
   gate vetoes poor fits so non-shapes stay rejected.

## Inputs and outputs

- **Input:** an ordered list of stroke points in canvas coordinates. Single stroke.
- **Output:** a shape class plus fitted geometry, or nothing if the stroke is rejected.

## Classes

`line`, `rectangle`, `triangle`, `ellipse`, `star`, plus `none` (the reject class:
scribbles, partial shapes, and other non-shape strokes). Squares and circles are
covered by `rectangle` and `ellipse` (snapped when near-regular).

## Limitations

- Single stroke only; multi-stroke shapes aren't recognized.
- Tuned for deliberate shapes; very rough or ambiguous strokes are rejected by design.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for
most apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

## Citation

```bibtex
@software{shapes_2026,
  title  = {Shapes: on-device shape recognition from a single stroke},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/shapes},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
