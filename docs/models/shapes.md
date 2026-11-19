<!-- model:start -->
# Shapes

Snap hand-drawn shapes to clean ones.

On-device shape recognition for pen, touch and mouse input.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Weights** | [v2.2.0](https://huggingface.co/desert-ant-labs/shapes/tree/v2.2.0) |
| **Demo** | https://desertant.com/models/shapes/ |
<!-- model:end -->

Draw a rough circle and Shapes snaps it to a clean one. Boxes, diamonds, stars, hearts, clouds, arrows and connectors snap the same way, drawn in one stroke or several. Shapes works with a pen, a finger, a mouse or a trackpad. It recognizes a stroke in 0.92ms on an iPhone 16 Pro.

Shapes also recognizes six marks: a check, a cross, a plus, a bracket, a zigzag and a scribble. The app decides what each mark does: a check can tick off an item, and a cross can reject a step. Shapes returns each shape in canvas coordinates, as the points and sizes to draw it, such as the four corners of a box.

<!-- model-install:start -->
## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "5.0.0")
```

Then add the `Shapes` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:shapes:5.0.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/shapes @litertjs/core   # browser
npm i @desert-ant-labs/shapes                  # Node, prebuilt native core
```
<!-- model-install:end -->

## Usage

### Swift

```swift
import Shapes

let shapes = Shapes()
let shape = try await shapes.recognize(strokes: [
    Stroke(points: across),                        // the strokes since the user paused, in drawing order
    Stroke(points: down),
])
switch shape {
case let .rectangle(corners)?: ...                 // [Point], around the perimeter
case let .arrow(from, _, _, to, startHead, endHead)?: ...
case let .plus(firstFrom, firstTo, secondFrom, secondTo)?: ...
case let .scribble(hull)?: ...                     // delete what the hull covers
case let shape?: draw(shape.paths())               // polylines for any shape
case nil: ...                                      // not a shape: keep the ink
}
```

Pass the strokes of one drawing: the app decides which strokes belong together, usually the strokes since the user last paused. For a single stroke, `recognize(points:)` takes its points. A `Stroke` can also carry the time of each point in milliseconds; give times for every stroke or for none.

Each call takes `Options`:

- `rotation`: `.snapped` is the default. Shapes rounds a shape's rotation to 15° steps and snaps lines and edges within 5° of horizontal or vertical onto the axis. `.upright` removes rotation: boxes and ellipses align with the axes, a plus sits on the axes and a cross at 45°. `.free` keeps the shape as drawn.
- `kinds`: the kinds Shapes recognizes. Leave out `.scribble` if the app has no erase gesture, or `.arrow` if the app adds arrowheads to lines itself.
- `minimumConfidence`: the lowest model confidence Shapes accepts, on top of its own checks.
- `isFinished`: `true` by default, for the moment the pen lifts. A finished outline snaps only once the whole outline is drawn, so a box missing a side comes back `nil`. Pass `false` for a preview while the pen still moves.

Unless `rotation` is `.free`, Shapes also snaps a near-square box to a square, a near-circular ellipse to a circle and a near-regular polygon to a regular one. The two strokes of a plus or a cross meet square, with equal arms when they're close in length; a bracket's spine is straight and its ends square; a check's corner is square.

`Shape.paths(samples:)` returns polylines for any shape, one per stroke for a plus or a cross, and `Shape.arrowheads(length:)` returns an arrow's heads. On Apple platforms, `Shape.path` returns a `CGPath`.

On iOS and visionOS, `enableShapeSnapping()` turns on live snapping in a PencilKit canvas. When the user pauses mid-stroke, the canvas previews the recognized shape. When the user lifts the pen, the SDK replaces the stroke with the clean shape, and a scribble erases the strokes inside its hull. Strokes drawn with no pause longer than `strokeGap`, 1s by default, are read together, so a plus drawn in two strokes snaps as a plus. The SDK registers each change with the canvas's undo manager, so undo and redo work.

```swift
canvasView.enableShapeSnapping()
```

### Kotlin

```kotlin
import ai.desertant.shapes.Options
import ai.desertant.shapes.Rotation
import ai.desertant.shapes.Shape
import ai.desertant.shapes.Shapes
import ai.desertant.shapes.Stroke

Shapes(context).use { shapes ->
    val shape = shapes.recognize(listOf(Stroke(across), Stroke(down)), Options(rotation = Rotation.UPRIGHT))
    when (shape) {
        is Shape.Scribble -> eraseUnder(shape.hull)
        is Shape.Arrow -> draw(shape.outline, shape.arrowheads(length = 12.0))
        null -> keepInk()
        else -> draw(shape.paths)
    }
}
```

### JavaScript

```ts
import { Shapes, arrowheads } from "@desert-ant-labs/shapes";       // browser
// import { Shapes } from "@desert-ant-labs/shapes/native";           // server-side Node

const shapes = await Shapes.load();
const shape = await shapes.recognize([{ points: across }, { points: down }], { rotation: "upright" });
if (shape?.kind === "scribble") eraseUnder(shape.hull);
else if (shape?.kind === "arrow") draw(shape.outline, arrowheads(shape, 12));
else if (shape) draw(shape.paths);                                    // null: keep the ink
shapes.dispose();
```

`recognize` also takes one stroke as `[{x, y}, ...]` or `[x0, y0, x1, y1, ...]`. In Kotlin and JavaScript, `paths` gives a plus or a cross as its two strokes, as `paths()` does in Swift.

### What comes back

The kinds and their fields are the same in Swift, Kotlin and TypeScript. Every shape also has an `outline`.

| Kind | Fields |
| --- | --- |
| `line` | `from`, `to`: a straight connector |
| `curve` | `from`, `control1`, `control2`, `to`: a curved connector, a cubic Bezier |
| `arrow` | `from`, `control1`, `control2`, `to`, `startHead`, `endHead`: a connector with a head at one or both ends |
| `rectangle` | `corners`: four points around the perimeter; a square is a rectangle |
| `ellipse` | `center`, `semiMajor`, `semiMinor`, `rotation`; a circle is an ellipse |
| `triangle`, `diamond`, `pentagon`, `hexagon` | `vertices`, around the perimeter |
| `star` | `center`, `outerRadius`, `innerRadius`, `rotation`, `pointCount` |
| `heart` | `center`, `width`, `height`, point down |
| `cloud` | the outline of its bumps |
| `check` | `start`, `corner`, `end`: the short arm's end, the corner, the long arm's end |
| `cross`, `plus` | `firstFrom`, `firstTo`, `secondFrom`, `secondTo`: its two strokes |
| `bracket` | `points`: from its top end, through its two corners, to its other end |
| `zigzag` | `from`, `to`, `amplitude`, `teeth`: `2 * teeth` straight runs |
| `scribble` | `hull`: the convex hull of the scribble, for an erase gesture |

For a drawing that isn't one of these kinds, or an outline that isn't finished, Shapes returns `nil` (`null` in Kotlin and JavaScript).

### Loading the model

Every SDK downloads the weights from Hugging Face on first use and caches them. See [model downloads and caching](../../README.md#model-downloads-and-caching).

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `coreml-palette4/shapes.mlmodelc` | Compiled Core ML, 4-bit palettized weights | 860KB | The model on Apple platforms (Swift SDK) |
| `litert-int8/shapes.tflite` | LiteRT, 8-bit weights | 1.8MB | The same model on Android, Linux, Windows, Node and the web (Kotlin, JavaScript, and Swift off Apple platforms) |
| `coreml-palette4/shapes_meta.json`, `litert-int8/shapes_meta.json` | JSON | 9KB | The kinds in output order, how the SDK prepares a drawing, where each kind's numbers sit in the outputs, and the limits of the checks after the model |

## Inputs and outputs

The SDK prepares a drawing of up to 32 strokes as 256 points spread along its ink, with five numbers per point: x, y, the step to the next point in x and in y, and whether a stroke starts there. Both builds take `x` `[1, 256, 5]` and `stroke` `[1, 256]` (each point's stroke) and return `kind_logits` `[1, 18]`, a score for each of the 17 kinds and for not a shape, and `numbers` `[1, 125]`, the numbers of every kind's template. The SDK takes the most likely kind, fits its template to the ink from those numbers, checks that the fit lies on the ink and that a closed outline is drawn, and snaps the shape per `Options`.

## Results

On flowcharts people drew by hand, Shapes recognizes the right kind for 98.4% of boxes, ovals, diamonds and arrows. On quick doodles from a drawing game, Shapes gets 85.7% right, and the gemstones in the diamond class pull that figure down.

We tested Shapes on two public sets of drawings that the model never trained on, through the Swift SDK on the Core ML files. Each figure is the share of drawings where the model's most likely kind is the kind drawn, before the SDK checks the fit.

| Set | Kind | Drawings | Accuracy |
|---|---|---:|---:|
| Quick, Draw! | all nine | 11,750 | 85.7% |
| | circle | 1,321 | 91.4% |
| | cloud | 1,221 | 94.2% |
| | diamond | 1,313 | 33.9% |
| | hexagon | 1,432 | 88.5% |
| | line | 1,418 | 88.1% |
| | square | 1,269 | 92.0% |
| | star | 1,364 | 96.3% |
| | triangle | 1,225 | 95.7% |
| | zigzag | 1,187 | 92.3% |
| DIDI | all four | 28,102 | 98.4% |
| | arrow | 14,632 | 98.2% |
| | box | 4,583 | 98.4% |
| | diamond | 4,505 | 98.3% |
| | oval | 4,382 | 99.0% |

Quick, Draw! is Google's set of doodles people drew in under 20 seconds in a browser game. We used every test drawing in the nine classes that match a Shapes kind. Most drawings in its diamond class are faceted gemstones, which Shapes treats as not a shape.

DIDI is Google's set of flowcharts people drew by hand, copying a diagram shown on screen. We cut every clean box, oval, diamond and arrow out of its 7,330 test drawings, matching each drawing to the diagram it copied.

On Android, Linux, Windows and the web, the LiteRT file scores within 0.6 points of the Core ML file on both sets.

No public set of drawings holds checks, crosses, pluses, brackets, scribbles, pentagons or hearts, so the table leaves those kinds out.

## Performance

Shapes recognizes a stroke in 0.56ms on a MacBook Pro M5 Pro and in 1.4ms on Linux. Each time is the median of 100 calls through the SDK, after a warm-up, for one stroke of up to 96 points. The times leave out loading the model.

| Device | Runtime | Per stroke |
| --- | --- | ---: |
| MacBook Pro, M5 Pro | Core ML | 0.56ms |
| iPhone 16 Pro | Core ML | 0.92ms |
| Linux, x86-64 | LiteRT, CPU | 1.4ms |
| MacBook Pro 16, M1 Max | Core ML | 2.8ms |
| Mac mini, M1 | Core ML | 3.0ms |
| Windows, AMD Ryzen AI 300 | LiteRT, CPU | 3.4ms |
| Windows, Intel Core Ultra 200V | LiteRT, CPU | 7.8ms |

## Limitations

- Shapes recognizes one shape per call, and the app decides which strokes belong to it. Two shapes passed in one call come back as not a shape or as one of the two.
- Shapes often reads a hand-drawn pentagon as a hexagon. Of 20 pentagons one person drew on a trackpad, Shapes read 17 as hexagons.
- A loose scribble of loops often comes back as not a shape. Of 20 such scribbles from the same person, Shapes read none as scribbles.
- A diamond drawn as a faceted gemstone comes back as not a shape or a triangle.
- A box drawn only halfway sometimes comes back as an open mark, such as a check, a bracket or a zigzag: up to 19 of 300 boxes on Apple platforms and 28 of 300 on Android, Linux, Windows and the web. Once 70% of the box is drawn, at most 1 of 300 does.

<!-- model-footer:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

Third-party notices for the weights: [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/shapes/blob/main/THIRD_PARTY_NOTICES.md).

## Citation

```bibtex
@software{shapes_2026,
  title  = {Shapes: On-device shape recognition for pen, touch and mouse input},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/shapes},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
<!-- model-footer:end -->
