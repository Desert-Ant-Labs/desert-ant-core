<!-- model:start -->
# Eye

Score, tag, and crop photos.

On-device photo understanding: scenes, quality, faces, people, pets, crops and sharpness.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Weights** | [v1.0.0](https://huggingface.co/desert-ant-labs/eye/tree/v1.0.0) |
| **Demo** | https://desertant.com/models/eye/ |
| **Status** | Beta |
<!-- model:end -->

Eye tags photos on device so apps can find and filter them: what a photo is (screenshot, receipt, selfie), what is in it (558 scenes), how it came out (blurry, eyes closed), who is in it (group shot, portrait) and whether it is sensitive, each with a calibrated confidence where 0.5 is the recommended cutoff and 0.9 a strict one. It also scores photos, finds people, pets and faces, and picks crops.

<!-- model-install:start -->
## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.2.3")
```

Then add the `Eye` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:eye:4.2.3")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/eye @litertjs/core   # browser
npm i @desert-ant-labs/eye                  # Node, prebuilt native core
```
<!-- model-install:end -->

## Usage

One call tags a photo. Filter with `has`, rank with `confidence` or `scores`, and group with the helpers on `Eye`.

### Swift

```swift
import Eye

let eye = Eye()
let photo = try await eye.analyze(contentsOf: photoURL)   // or UIImage, NSImage, CGImage, Data

if photo.has(.screenshot) || photo.has(.receipt) { archive(photo) }
if photo.has(.dog) && !photo.has(.blurry) { keep(photo) }
if photo.has(.sensitive, .strict) { hide(photo) }

photo.tags()                      // [.photo, .beach, .people, .smiling, ...], most confident first
photo.confidence(.beach)          // 0.93
photo.kind                        // .photo, .selfie, .screenshot, .document, ...
photo.scores?.aesthetic           // 0.81: better than 81% of photos
photo.faces?.first?.has(.eyesClosed)
photo.bestCrop(aspect: 1)         // a square thumbnail, in 0...1 of the image
photo.rotation                    // 90: turned a quarter turn clockwise, so turn it back

let groups = Eye.duplicates(in: library, dates: captureTimes)   // [[Int]], best first
let keeper = Eye.best(of: burst)
```

The SDK decodes files and `Data` upright, following their EXIF orientation. A `UIImage` keeps its orientation and full pixel resolution. Canceling the calling task stops the analysis and throws `CancellationError`.

On Linux and Windows, pass decoded pixels:

```swift
let pixels = try ImagePixels(width: w, height: h, rgba: bytes)
let photo = try await eye.analyze(pixels)
```

### Kotlin

```kotlin
import ai.desertant.eye.Eye
import ai.desertant.eye.Tags

Eye(context).use { eye ->
    val photo = eye.analyze(bitmap)            // or analyze(bytes, width, height)
    if (photo.has(Tags.DOG) && !photo.has(Tags.BLURRY)) keep(photo)
    val groups = Eye.duplicates(library)
}
```

### JavaScript

```ts
import { Eye, Tag } from "@desert-ant-labs/eye";         // browser
// import { Eye, Tag } from "@desert-ant-labs/eye/native"; // server-side Node
const eye = await Eye.load();
const photo = await eye.analyze(image);
if (photo.has(Tag.dog) && !photo.has(Tag.blurry)) keep(photo);
const groups = Eye.duplicates(library, { dates });
eye.dispose();
```

In the browser, `image` can be anything `createImageBitmap` accepts (an `<img>`, a canvas, a `Blob`, an `ImageBitmap`) or an `ImageData`. In Node, pass decoded, upright pixels as `{ data, width, height }` with RGB or RGBA bytes, for example from `sharp(file).rotate().raw().toBuffer({ resolveWithObject: true })`. The browser build runs the model on the GPU through WebGPU when the browser has it, and on the CPU through WebAssembly otherwise; pass `accelerator: "wasm"` or `"webgpu"` to `Eye.load` to choose.

### Tags

Every tag has a confidence from 0 to 1, calibrated so that the same two cutoffs work for every tag:

| Cutoff | `has(tag)` | Use it for |
| --- | --- | --- |
| 0.5, recommended | `has(.dog)` | The balance of precision and recall we recommend: filters, collections, search |
| 0.9, strict | `has(.dog, .strict)` | High precision: anything that acts without asking, such as hiding or deleting |

| Group | Tags |
| --- | --- |
| Photo type | `photo`, `selfie`, `screenshot`, `photo_of_screen`, `receipt`, `document`, `id_card`, `whiteboard`, `map`, `chart_or_slide`, `meme_or_graphic`, `illustration_or_art`, `shopping_reference`, `medical_reference`, `repair_reference`, `other`, and `reference` for any capture taken to remember something |
| Keep or delete | `keeper`, `forgettable`, `accidental`, `technical_flaw`, `unusable`, `bad_framing`, `bad_lighting`, `test_or_duplicate_shot`, `reference_photo`, `low_content` |
| Quality | `sharp`, `blurry` (whole frame soft and no sharp subject), `bokeh` (a sharp subject against a soft background), `peak_moment`, `rotated` |
| People | `people`, `group_shot` (three or more faces), `portrait` (one main face), `smiling`, `eyes_closed`, `everyone_smiling`, `everyone_looking`, `candid` |
| Faces | `eyes_closed`, `smiling`, `looking_at_camera`, `looking_away`, `happy`, `surprised`, on each `Face` |
| Sensitive | `sensitive` (any of these), `nsfw_explicit`, `nsfw_suggestive`, `blood_injury`, `medical_hospital`, `funeral`, `accident_disaster`, `violence_protest`, `weapon` |
| Scenes | 558 Open Images classes, such as `dog`, `beach`, `food`, `car`, `mountain` |

The constants (`Tag.dog`, `Tags.DOG` in Kotlin, `Tag.dog` in JavaScript) cover every tag of the model this SDK pins. A newer model may add tags; `Tag("name")` reaches any of them.

### Options

| Option | Default | |
| --- | --- | --- |
| `parts` | all | What to compute: `photo` (types, scenes, keep or delete, sensitive, scores, embedding), `layout` (people and pet boxes, crops), `faces`, `sharpness`. Each part is one or more model runs, so leave out what you do not need. Tags that need a part you left out are absent, not false: `blurry` needs `photo`, `faces` and `sharpness`. |
| `maxFaces` | `20` | The most faces analyzed per photo, most confident first. |

### Storing results

Everything except `details` serializes to the same JSON in every SDK (`Codable` in Swift, `toJson()` in Kotlin, `JSON.stringify` in JavaScript). Store analyses and filter or group them later without loading the model. `model` records which model version produced each one.

### Across photos

| Call | Returns |
| --- | --- |
| `Eye.duplicates(in:dates:)` | Groups of near-duplicates, best first. With capture times (seconds), only photos taken within seconds of each other count. |
| `Eye.best(of:)` | The photo to keep from a set: no one's eyes closed, then the best faces, then the keeper score. |
| `Eye.similar(to:in:limit:)` | Photos ranked by embedding similarity. |
| `analysis.similarity(to:)` | Cosine similarity of two photos' embeddings. |

### Raw outputs

`details` holds the model's raw outputs (every scene score, the aesthetic attributes, the 64x64 attention map, all 1,296 crop scores, the blur map, every face's raw readings) for the cases tags and scores do not cover.

### Loading the model

The SDK downloads the weights from Hugging Face on first use and caches them. See [model downloads and caching](../../README.md#model-downloads-and-caching).

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `eye.mlmodelc` | Compiled Core ML, one function per part | 48MB | Ready to load on Apple platforms (used by the Swift SDK), every function on the Neural Engine |
| `eye.tflite` | LiteRT / TFLite (int8 weights), one signature per function | 66MB | Runs on Android, Linux, Windows, Node, and the web (downloaded on demand by the Kotlin and JavaScript SDKs) |
| `eye_meta.json` | JSON | 281KB | Inputs, outputs, the constants the SDK decodes outputs with, and the tags' calibration curves and rules |

## Functions

Both files hold the same functions under the same names. Every input is RGB (or gray for sharpness) in `0...1`, shape `(1, C, H, W)`: float16 for Core ML, float32 for LiteRT. `eye_meta.json` has the exact preparation and how to decode each output.

| Function | Input | Outputs |
|---|---|---|
| `photo` | 384x384 centre crop | embedding, type, reject reasons, sensitive content, scenes, rotation, aesthetic, keeper, cover, focus and bokeh, pet attributes |
| `photo_peak` | as `photo` | `photo`'s outputs and the peak moment |
| `spatial` | whole frame squashed to 384x384 | where people look, pet and person boxes, shot type, scores for 1,296 crop boxes |
| `faces_detect` | 768x768, the photo letterboxed | face heatmap, size, offset, landmarks |
| `faces_analyze` | 128x128 crop, 1.4x a face box | eyes open, blink, smile, gaze, expression, pose, quality and more |
| `sharp_4x3`, `sharp_3x4`, `sharp_16x9`, `sharp_9x16` | gray, the shape closest to the photo's aspect | sharpness, blur map |

## Tag accuracy

Every tag has a confidence calibrated so 0.5 is the recommended cutoff and 0.9 a strict one. At 0.5: photo types 0.8 to 1.0 precise (screenshot 0.98, receipt 1.00), scenes 0.88 median, people 0.95, eyes closed 0.92. The keep-or-delete reasons (forgettable, bad framing, ...) are less reliable; use them for suggestions. For anything automatic, such as hiding sensitive photos, use the strict cutoff.

## Accuracy

On the same test sets, through the same scoring code:

| Test set | Metric | `eye.mlmodelc` | `eye.tflite` (CPU) |
|---|---|---:|---:|
| KonIQ-10k | aesthetic SRCC | 0.6288 | 0.6291 |
| COCO val2017 | person AP50 | 0.3814 | 0.3837 |
| MIT1003 | where people look, CC | 0.7153 | 0.7195 |
| CUHK cropping | crop IoU | 0.8244 | 0.8241 |
| WIDER Face val | AP, hard | 0.6806 | 0.6812 |
| CEW | eyes open AUC | 0.9943 | 0.9945 |

## Speed

One photo, `photo_peak`, on a Mac with an Apple M6:

| Runtime | ms |
|---|---:|
| Core ML, Neural Engine | 5.5 |
| LiteRT, GPU (Metal) | 30 |
| LiteRT.js, WebGPU, in Chrome | 41 |
| LiteRT, CPU, 4 threads | 49 |
| LiteRT.js, wasm with threads, in Chrome | 176 |

## Limitations

- `eye.tflite` is not yet measured on Android devices.
- Face analysis describes a face. It doesn't identify who someone is.
- Eye is trained on photos. Scores for illustrations, screenshots and heavily edited images are less reliable.

## Built on

- Image encoder: [PE-Core S/16-384](https://huggingface.co/facebook/PE-Core-S16-384) by Meta, Apache 2.0, fine-tuned and with heads trained by Desert Ant Labs.
- The face detector, face analyzer and sharpness model are Desert Ant Labs' own, trained from scratch.

<!-- model-footer:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

Third-party notices for the weights: [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/eye/blob/main/THIRD_PARTY_NOTICES.md).

## Citation

```bibtex
@software{eye_2026,
  title  = {Eye: On-device photo understanding: scenes, quality, faces, people, pets, crops and sharpness},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/eye},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
<!-- model-footer:end -->
