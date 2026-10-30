<!-- model:start -->
# Moderator

Flag nudity before upload or display.

On-device NSFW image detection, trained only on licensed and synthetic data.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Weights** | [v1.0.0](https://huggingface.co/desert-ant-labs/moderator/tree/v1.0.0) |
| **Demo** | https://desertant.com/models/moderator/ |
<!-- model:end -->

Score an image from 0 to 1 for nudity or sexual activity. Threshold it (default 0.5) and you have your answer. Tuned to pass real swimwear and lingerie photos while flagging real nude and sexual content. The model is small (**9.7MB** on Apple via Core ML, **9.2MB** via LiteRT elsewhere) and runs fully on device, with images never leaving it.

Per-region detail (nipples, genitals, buttocks, nudity, sexual activity) is available for policies that need it, for example allow-topless.

<!-- model-install:start -->
## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.2.2")
```

Then add the `Moderator` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:moderator:4.2.2")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/moderator @litertjs/core   # browser
npm i @desert-ant-labs/moderator                  # Node, prebuilt native core
```
<!-- model-install:end -->

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

The SDK decodes files and `Data` upright, following their EXIF orientation. A `UIImage` keeps its orientation and full pixel resolution. Canceling the calling task stops the analysis and throws `CancellationError`.

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

In the browser, `image` can be anything `createImageBitmap` accepts (an `<img>`, a canvas, a `Blob`, an `ImageBitmap`) or an `ImageData`. In Node, pass decoded pixels as `{ data, width, height }` with RGB or RGBA bytes, for example from `sharp(file).raw().toBuffer({ resolveWithObject: true })`.

### Options

Every SDK accepts the same three options:

| Option | Default | |
| --- | --- | --- |
| `threshold` | `0.5` | The score at or above which `isNSFW` is true. Raise the threshold to flag fewer safe images, at the cost of missing more NSFW ones. |
| `policy` | standard | `allowTopless` ignores a bare chest on its own. Exposed genitals or buttocks, full nudity and sexual activity still flag. |
| `quality` | accurate | How many crops the SDK scores per image. The score is the max across crops. `fast` scores one center crop, for video frames. `balanced` scores four multiscale tiles. `accurate` scores those tiles and their mirrors, the setting the model is evaluated with. |

The score is the highest of the region scores that the policy counts. Region scores rank images, but they aren't calibrated probabilities: a 0.8 doesn't mean an 80% chance.

### Loading the model

The SDK downloads the weights from Hugging Face on first use and caches them. See [model downloads and caching](../../README.md#model-downloads-and-caching).

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `moderator.mlmodelc` | Compiled Core ML (int8) | 9.7MB | Ready to load on Apple platforms (used by the Swift SDK) |
| `moderator.tflite` | LiteRT / TFLite (int8) | 9.2MB | Runs on Android, Linux, Windows, Node, and the web (downloaded on demand by the Kotlin and JavaScript SDKs) |

## Inputs and outputs

- **Input:** an image. The SDKs take platform images, files, or raw RGB(A) pixels.
- **Output:** an NSFW score from 0 to 1 and a yes/no decision at your threshold (default 0.5), plus a confidence per region: `nipples`, `genitals`, `buttocks`, `nude`, and `sexAct`. The score is the highest region the policy counts; allow-topless leaves out `nipples`.

Trade speed for recall with the SDK's `quality` setting:

| Quality | Recall | Specificity | Use for |
|---|---:|---:|---|
| `fast` | 74% | 97% | Video frames; sampling across frames recovers recall |
| `balanced` | 84% | 95% | Higher per-frame recall |
| `accurate` (default) | 88% | 94% | Single images |

## Training data

This is the rare NSFW model with fully controlled data provenance. Nothing is scraped from the open internet. Every training image is either permissively licensed (public domain or Creative Commons) or generated in-house. Positives are drawn from public-domain fine art and museum open-access collections (classical nudes in painting, sculpture, and photography), historic and documentary photography, and openly-licensed imagery, plus photorealistic images generated with generative image models.

Clean, controlled provenance end to end is unusual for an NSFW classifier, where scraped datasets of unknown origin are the norm. It means no copyright or licensing exposure, and a model you can put in a commercial product with confidence.

## Evaluation

Held-out evaluation set (464 images, 75% SFW / 25% NSFW), scored on the single NSFW score at threshold 0.5 with the default `accurate` quality.

| Metric | Moderator | NudeNet |
|---|---|---|
| Recall (catches NSFW) | **87.8%** | 82.6% |
| Specificity (SFW passed) | **93.7%** | 87.1% |
| False-block rate (SFW flagged) | **6.3%** | 12.9% |

Moderator beats NudeNet on both recall and precision, and flags about half as many SFW images.

## Limitations

- Adult-content classifier only. Subjects rendered as minors are out of scope by design; the training corpus excludes them and the model is not validated for that population.
- Accuracy is lower on difficult images (crowded scenes, extreme close-ups, low light, or low resolution) than on clear, well-lit ones.
- Anime/hentai and heavily-censored (mosaic) content are out of scope; the model is trained on photoreal.
- This is a content-moderation aid, not a legal determination. Use with human review for any decision the model is the only gate on.

<!-- model-footer:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

Third-party notices for the weights: [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/moderator/blob/main/THIRD_PARTY_NOTICES.md).

## Citation

```bibtex
@software{moderator_2026,
  title  = {Moderator: On-device NSFW image detection, trained only on licensed and synthetic data},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/moderator},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
<!-- model-footer:end -->
