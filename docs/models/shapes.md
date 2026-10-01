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
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.6.0")
```

Then add the `Shapes` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:shapes:3.6.0")
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

`recognize` accepts `[Point]` on every platform. On Apple platforms, `recognize` also accepts `[CGPoint]` and a PencilKit `PKStroke`, and `Shape.path` gives you a `CGPath` to draw.

On iOS and visionOS, one line turns on live snapping in a PencilKit canvas. When the user pauses mid-stroke, the canvas previews the recognized shape. When the user lifts the pen, the SDK swaps in the clean shape. The SDK registers the swap with the canvas's undo manager, so undo and redo work.

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

The Swift and JavaScript SDKs download the weights from Hugging Face on first use and cache them. The Kotlin SDK bundles the weights by default. See [model downloads and caching](../../README.md#model-downloads-and-caching).

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `shapes.tflite` | LiteRT / TFLite (fp32) | 1.3MB | Fixed `[1,256,3]` feature window and `[1,256]` mask. Shapes runs this file on Android, Linux, Windows, Node and the browser. The Kotlin SDK bundles the file by default, and the JavaScript SDK downloads the file on demand. |
| `shapes.mlmodelc` | Compiled Core ML | 0.2MB | 4-bit palettized classifier. The Swift SDK loads this file on Apple platforms. |
| `shapes_meta.json` | JSON | tiny | Classes, preprocessing constants, model dimensions, and the per-class thresholds that decide whether Shapes accepts a stroke. |
| `shapes.safetensors` | safetensors | 0.2MB | Weights for older SDK versions that load tag `v0.1.0`. The current SDKs don't load this file. |

## Inputs and outputs

Pass the points of a single stroke, in order, in canvas coordinates. Shapes returns the shape class and its fitted geometry, so you can draw the clean shape in place of the stroke. When Shapes rejects the stroke, you get nothing back.

## Classes

Shapes recognizes `line`, `rectangle`, `triangle`, `ellipse` and `star`. Shapes rejects scribbles, partial shapes and other strokes that aren't shapes as the `none` class. `rectangle` covers squares, and `ellipse` covers circles. Shapes snaps a near-regular rectangle to a square and a near-regular ellipse to a circle.

## Limits

- Shapes doesn't recognize a shape drawn in more than one stroke.
- Shapes rejects very rough or ambiguous strokes, so a hasty sketch can come back as no shape.

## License

Shapes is available under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Most apps can use Shapes for free. At scale, you need a commercial license. The link has the full terms. For licensing, email <licensing@desertant.com>.
