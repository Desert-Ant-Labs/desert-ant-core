<!-- model:start -->
# Shapes

Rough sketch. Perfect shape.

On-device single-stroke shape recognition.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Weights** | [v0.3.0](https://huggingface.co/desert-ant-labs/shapes) |
| **Demo** | https://desertant.com/models/shapes/ |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.0.0")
```

Then add the `Shapes` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:shapes:3.0.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/shapes @litertjs/core   # browser
npm i @desert-ant-labs/shapes                  # Node, prebuilt native core
```
<!-- model:end -->

## Usage

### Swift

```swift
import Shapes

let shapes = Shapes()
if let shape = try await shapes.recognize(points: strokePoints) {
    switch shape {
    case let .rectangle(corners): ...       // [Point]
    case let .ellipse(center, semiMajor, semiMinor, rotation): ...
    default: break
    }
}
```

`recognize` accepts `[Point]` or, on Apple platforms, `[CGPoint]` and PencilKit
`PKStroke`; `Shape.path` gives a renderable `CGPath`. On iOS and visionOS, live
snapping on a PencilKit canvas is one line. Pausing mid-stroke previews the
recognized shape, lifting the pen swaps it in, and the swap is registered with
the canvas's undo manager:

```swift
canvasView.enableShapeSnapping()
```

### Kotlin

```kotlin
import ai.desertant.shapes.Point
import ai.desertant.shapes.Shape
import ai.desertant.shapes.Shapes

Shapes(context).use { shapes ->
    when (val shape = shapes.recognize(strokePoints)) {   // Shape? (null if rejected)
        is Shape.Rectangle -> shape.corners
        is Shape.Ellipse -> shape.center
        else -> {}
    }
}
```

### JavaScript

```ts
import { Shapes } from "@desert-ant-labs/shapes";       // browser
// import { Shapes } from "@desert-ant-labs/shapes/native"; // server-side Node

const shapes = await Shapes.load();
const shape = await shapes.recognize(points);   // [{x, y}, ...] or [x0, y0, ...]
if (shape?.kind === "ellipse") shape.center;    // null when the stroke is rejected
shapes.dispose();
```

### Loading the model

The weights are fetched from the Hub on first use and cached. See
[model downloads and caching](../../README.md#model-downloads-and-caching).

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
