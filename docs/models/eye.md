<!-- model:start -->
# Eye

Score, tag, and crop photos.

On-device photo understanding: scenes, quality, faces, people, pets, crops and sharpness.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Weights** | [v1.0.0](https://huggingface.co/desert-ant-labs/eye) |
| **Demo** | https://desertant.com/models/eye/ |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.1.0")
```

Then add the `Eye` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:eye:4.1.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/eye @litertjs/core   # browser
npm i @desert-ant-labs/eye                  # Node, prebuilt native core
```
<!-- model:end -->

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

The SDK downloads the weights from Hugging Face on first use and caches them. See [model downloads and caching](../../README.md#model-downloads-and-caching). Eye is in closed beta: its weights are in a gated repository, so set `HF_TOKEN` to a token with access.

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `eye.mlmodelc` | Compiled Core ML, one function per part | 48MB | Ready to load on Apple platforms (used by the Swift SDK), every function on the Neural Engine |
| `eye.tflite` | LiteRT / TFLite (int8 weights), one signature per function | 66MB | Runs on Android, Linux, Windows, Node, and the web (downloaded on demand by the Kotlin and JavaScript SDKs) |
| `eye_meta.json` | JSON | 76KB | The output names and the constants the SDK decodes outputs with |

## License

Eye is available under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Most apps can use Eye for free. At scale, you need a commercial license. The link has the full terms. For licensing, email <licensing@desertant.com>.
