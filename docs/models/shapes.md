<!-- model:start -->
# Shapes

Rough sketch. Perfect shape.

On-device single-stroke shape recognition.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Weights** | [v1.0.0](https://huggingface.co/desert-ant-labs/shapes) |
| **Demo** | https://desertant.com/models/shapes/ |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.2.0")
```

Then add the `Shapes` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:shapes:4.2.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/shapes @litertjs/core   # browser
npm i @desert-ant-labs/shapes                  # Node, prebuilt native core
```
<!-- model:end -->

## Usage

Shapes turns a hand-drawn stroke into a clean shape, connector, or arrow. Shapes recognizes 13 kinds: a straight or curved connector, an arrow, a rectangle, an ellipse, a triangle, a diamond, a pentagon, a hexagon, a star, a heart, a cloud, and a scribble, which your app can use as an erase gesture. For a stroke that isn't one of these, such as handwriting or an unfinished shape, Shapes returns `nil` (`null` in Kotlin and JavaScript), so you can keep that stroke as ink. The kinds and their field names are the same in Swift, Kotlin, and TypeScript.

### Swift

```swift
import Shapes

let shapes = Shapes()
switch try await shapes.recognize(points: strokePoints) {
case let .rectangle(corners)?: ...                        // [Point], around the perimeter
case let .arrow(from, _, _, to, startHead, endHead)?: ... // a cubic shaft and its heads
case let .scribble(hull)?: ...                            // delete what the hull covers
case let shape?: draw(shape.outline())                    // a polyline for any shape
case nil: ...                                             // not a shape: keep the ink
}
```

Each `recognize` call takes three options:

- `rotation`: `.snapped` is the default. It rounds a shape's rotation to 15° steps and snaps lines and edges within 5° of horizontal or vertical onto the axis. `.upright` removes rotation: rectangles and ellipses align with the axes, each polygon has a horizontal edge or a vertex straight up, and each star has a tip straight up. `.free` keeps the shape as drawn.
- `kinds`: the kinds Shapes recognizes. Leave out `.scribble` if your app has no erase gesture, or `.arrow` if your app adds arrowheads to lines itself.
- `minimumConfidence`: the lowest classifier confidence Shapes accepts, on top of each kind's calibrated threshold.

For example, upright shapes only:

```swift
let shape = try await shapes.recognize(points: strokePoints, options: Options(rotation: .upright))
```

`recognize` accepts `[Point]` on every platform, and `[CGPoint]` or a PencilKit `PKStroke` on Apple platforms. `Shape.outline(samples:)` returns a polyline for any shape, and `Shape.arrowheads(length:)` returns an arrow's heads. On Apple platforms, `Shape.path` returns a `CGPath` that includes curves and arrowheads.

On iOS and visionOS, `enableShapeSnapping()` turns on live snapping in a PencilKit canvas. When the user pauses mid-stroke, the canvas previews the recognized shape. When the user lifts the pen, the SDK replaces the stroke with the clean shape, and a scribble erases the strokes inside its hull. The SDK registers each change with the canvas's undo manager, so undo and redo work. `ShapeSnappingConfiguration.options` takes the same `Options` as `recognize`.

```swift
canvasView.enableShapeSnapping()
```

### Kotlin

```kotlin
import ai.desertant.shapes.Options
import ai.desertant.shapes.Rotation
import ai.desertant.shapes.Shape
import ai.desertant.shapes.Shapes

Shapes(context).use { shapes ->
    when (val shape = shapes.recognize(strokePoints, Options(rotation = Rotation.UPRIGHT))) {
        is Shape.Scribble -> eraseUnder(shape.hull)
        is Shape.Arrow -> draw(shape.outline, shape.arrowheads(length = 12.0))
        null -> keepInk()
        else -> draw(shape.outline)
    }
}
```

### JavaScript

```ts
import { Shapes, arrowheads } from "@desert-ant-labs/shapes";       // browser
// import { Shapes } from "@desert-ant-labs/shapes/native";           // server-side Node

const shapes = await Shapes.load();
const shape = await shapes.recognize(points, { rotation: "upright" });  // [{x, y}, ...] or [x0, y0, ...]
if (shape?.kind === "scribble") eraseUnder(shape.hull);
else if (shape?.kind === "arrow") draw(shape.outline, arrowheads(shape, 12));
else if (shape) draw(shape.outline);                                  // null: keep the ink
shapes.dispose();
```

### Loading the model

Every SDK downloads the weights from Hugging Face on first use and caches them. See [model downloads and caching](../../README.md#model-downloads-and-caching).

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `shapes.tflite` | LiteRT / TFLite (int8 weights) | 0.95MB | The classifier, with input `points` `[1,128,2]` and outputs `probs` `[1,13]` and `head` `[1,128]`. Shapes runs this file on Android, Linux, Windows, Node, and the browser. |
| `shapes.mlmodelc` | Compiled Core ML | 0.7MB | The same classifier, 6-bit palettized. The Swift SDK loads this file on Apple platforms. |
| `shapes_meta.json` | JSON | tiny | The class order, the input length, and the per-kind thresholds that decide whether Shapes accepts a stroke. |

## Inputs and outputs

Pass the points of a single stroke, in order, in canvas coordinates. The SDK resamples the stroke to 128 points evenly spaced along its length. The model scores each kind and marks the points that belong to an arrowhead. A geometric fitter then computes the clean shape, in the same coordinates as the stroke. For a stroke that isn't a shape, Shapes returns `nil` (`null` in Kotlin and JavaScript).

## Kinds

Shapes recognizes `line` and `curve` (connectors), `arrow`, `rectangle`, `ellipse`, `triangle`, `diamond`, `pentagon`, `hexagon`, `star`, `heart`, `cloud`, and `scribble`. A square is a `rectangle`, and a circle is an `ellipse`.

Unless `rotation` is `.free`, Shapes snaps a near-square rectangle to a square, a near-circular ellipse to a circle, and a near-regular polygon to a regular one.

## Limits

- Shapes recognizes one stroke at a time. For an arrow drawn in two strokes, Shapes recognizes the shaft as a line.
- Shapes sometimes recognizes a curly brace or a check mark drawn with sharp turns as a scribble.
- Stars have 5 or 6 points.

## License

Shapes is available under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Most apps can use Shapes for free. At scale, you need a commercial license. The link has the full terms. For licensing, email <licensing@desertant.com>.
