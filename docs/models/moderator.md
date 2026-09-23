<!-- model:start -->
# Moderator

Flag nudity before upload or display.

On-device NSFW image detection, trained only on licensed and synthetic data.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Weights** | [v1.0.0](https://huggingface.co/desert-ant-labs/moderator) |
| **Demo** | https://desertant.com/models/moderator/ |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.4.0")
```

Then add the `Moderator` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:moderator:3.4.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/moderator @litertjs/core   # browser
npm i @desert-ant-labs/moderator                  # Node, prebuilt native core
```
<!-- model:end -->

## Usage

### Swift

```swift
import Moderator

let moderator = Moderator()
let result = try await moderator.analyze(contentsOf: photoURL)   // or UIImage, NSImage, CGImage, Data
if result.isNSFW { blur() }
print(result.score)        // 0...1
print(result.regions)      // nipples, genitals, buttocks, nude, sexAct
```

Files and `Data` are decoded upright per their EXIF orientation, and a
`UIImage` keeps its orientation and full pixel resolution. Cancelling the calling
task stops the analysis and throws `CancellationError`.

On Linux and Windows, pass decoded pixels:

```swift
let pixels = try ImagePixels(width: w, height: h, rgba: bytes)
let result = try await moderator.analyze(pixels)
```

### Kotlin

```kotlin
import ai.desertant.moderator.Moderator
import ai.desertant.moderator.Options

Moderator(context).use { moderator ->
    val result = moderator.analyze(bitmap)            // or analyze(bytes, width, height)
    if (result.isNSFW) blur()
}
```

### JavaScript

```ts
import { Moderator } from "@desert-ant-labs/moderator";         // browser
// import { Moderator } from "@desert-ant-labs/moderator/native"; // server-side Node

const moderator = await Moderator.load();
const { score, isNSFW, regions } = await moderator.analyze(image);
moderator.dispose();
```

In the browser `image` is anything `createImageBitmap` accepts (an `<img>`, a
canvas, a `Blob`, an `ImageBitmap`) or an `ImageData`. In Node pass decoded
pixels, `{ data, width, height }` with RGB or RGBA bytes, for example from
`sharp(file).raw().toBuffer({ resolveWithObject: true })`.

### Options

Every SDK takes the same three options:

| Option | Default | |
| --- | --- | --- |
| `threshold` | `0.5` | Score at or above which `isNSFW` is true. A product dial: raise it to trade recall for precision. |
| `policy` | standard | `allowTopless` ignores a bare chest on its own; exposed genitals or buttocks, full nudity, and sexual activity still flag. |
| `quality` | accurate | Crops scored per image, max taken. `fast` is one center crop (video frames), `balanced` four multiscale tiles, `accurate` those tiles and their mirrors, the setting the model is evaluated with. |

The score is the max of the region heads the policy counts. Regions are decision
scores, not calibrated probabilities.

### Loading the model

The weights are fetched from the Hub on first use and cached. See
[model downloads and caching](../../README.md#model-downloads-and-caching).

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `moderator.mlmodelc` | Compiled Core ML (int8) | 9.7MB | Ready to load on Apple platforms (used by the Swift SDK) |
| `moderator.tflite` | LiteRT / TFLite (int8) | 9.2MB | Runs on Android, Linux, Windows, Node, and the web (downloaded on demand by the Kotlin and JavaScript SDKs) |

The SDKs prepare images exactly as the model was evaluated, so a score here is
the score the model was measured on.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for
most apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.
