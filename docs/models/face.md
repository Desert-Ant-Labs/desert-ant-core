<!-- model:start -->
# Face

Find people in photos, on device.

On-device face matching across a photo library or through a video.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Weights** | [v1.0.0](https://huggingface.co/desert-ant-labs/face/tree/v1.0.0) |
| **Demo** | https://desertant.com/models/face/ |
<!-- model:end -->

Face finds the faces in a photo and gives each one a faceprint: 128 numbers that point the same way for the same person. With stored faceprints you can tell whether two faces are one person, find one person in a library from a selfie, and group a library into people, without the model. To crop, blur or count faces, `FaceDetector` finds them without faceprints and downloads the detector alone. No face leaves the device.

<!-- model-install:start -->
## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "5.0.0")
```

Then add the `Face` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:face:5.0.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/face @litertjs/core   # browser
npm i @desert-ant-labs/face                  # Node, prebuilt native core
```
<!-- model-install:end -->

## Usage

`faces(in:)` finds the faces in a photo and gives each one a faceprint. `FaceLibrary` groups faceprints into people and keeps the names and corrections the user makes. The library and the comparisons run without the model.

### Swift

```swift
import Face

let face = Face()
let faces = try await face.faces(contentsOf: photoURL)   // or UIImage, NSImage, CGImage, Data
faces.first?.box          // in 0...1 of the image, origin top left
faces.first?.faceprint    // Codable, or .data (512 bytes) for your own database

var library = FaceLibrary()
library.add(faces, photo: asset.id, date: asset.creationDate)
for person in library.people(.prominent) {               // or .all
    show(person.name, library.face(person.keyFace)?.box)
}

library.name(person.id, "Noor")
library.confirm(faceID, is: person.id)         // "This is Noor"
library.reject(faceID, from: person.id)        // "This is not Noor"
library.merge(other.id, into: person.id)       // "These are the same person"
library.newPerson(from: faceID, named: "Ana")  // "This is Ana", someone new
library.suggestions(for: person.id)            // "Is this also Noor?"
library.remove(photo: deletedAsset.id)
library.person(for: newFace.faceprint)?.name   // "Noor", or nil for someone new
```

The SDK decodes files and `Data` upright, following their EXIF orientation. Face also finds faces turned sideways or upside down in the photo, and their faceprints match the same faces upright. Canceling the calling task stops the analysis and throws `CancellationError`. Create one `Face` and reuse it.

On Linux and Windows, pass decoded pixels:

```swift
let pixels = try ImagePixels(width: w, height: h, rgba: bytes)
let faces = try await face.faces(in: pixels)
```

### Kotlin

```kotlin
import ai.desertant.face.Face

Face(context).use { face ->
    val library = face.library()                       // or face.library(saved), face.library(rows, names)
    library.add(face.faces(bitmap), photo = assetId, date = takenAt)
    for (person in library.people(prominent = true)) show(person)
    library.name(person.id, "Noor")
    library.reject(faceId, person.id)                  // "This is not Noor"
    library.newPerson(faceId, "Ana")                   // "This is Ana", someone new
    library.person(newFace.faceprint)?.name            // "Noor"
    val saved = library.save()                         // JSONObject
}
```

### JavaScript

```ts
import { Face } from "@desert-ant-labs/face";          // browser
// import { Face } from "@desert-ant-labs/face/native"; // server-side Node
const face = await Face.load();
const library = await face.library();                  // or face.library(saved)
await library.add(await face.faces(image), photoId, { date });
const people = await library.people({ prominent: true });
await library.name(people[0].id, "Noor");
const saved = await library.save();                    // JSON
face.dispose();
```

In the browser, `image` can be anything `createImageBitmap` accepts or an `ImageData`. In Node, pass decoded, upright pixels as `{ data, width, height }`.

### Faces without faceprints

`FaceDetector` finds the faces and their five landmarks, and downloads the detector alone: 7.6 MB on Apple platforms, 15 MB elsewhere, against 26 MB and 52 MB for `Face`. `Face` and Eye use the same detector, and an app that uses more than one of them downloads it once.

```swift
let detector = FaceDetector()
for face in try await detector.faces(contentsOf: photoURL) {   // [FaceDetection]: box, landmarks, confidence
    blur(face.box)
}
```

```kotlin
FaceDetector(context).use { detector -> detector.faces(bitmap).forEach { blur(it.box) } }
```

```ts
import { FaceDetector } from "@desert-ant-labs/face";
const detector = await FaceDetector.load();
for (const { box } of await detector.faces(image)) blur(box);
```

`FaceDetector` finds the same faces as `Face` when given the same options. A `DetectedFace` from `Face` gives its `FaceDetection` as `detection`.

### Saving a library

The library's state is `faces`, one `FaceRecord` per face, and `names`. Every platform runs the same Swift `FaceLibrary`, so a library saved on one platform loads on any other and groups faces the same way.

To save the whole library, encode it as JSON (`Codable` in Swift, `save()` in Kotlin and JavaScript) and decode it at launch.

To keep faces in your own database, store each `FaceRecord` as one row of a faces table (`id`, `photo`, `date`, `box`, `confidence`, `faceprint.data`, `person`, `confirmed`, `rejected`) and `names` as a people table:

1. Add each face with your own id: `library.add(detected, id: row.id, photo: asset.id, date: asset.creationDate)`.
2. After adding, naming or fixing, write the rows that changed: `for record in library.takeChanges() { db.save(record) }`, and save `library.names`.
3. At launch, rebuild the library from your rows: `FaceLibrary(faces: db.faceRecords(), names: db.names())`. The library doesn't regroup on load. Rows you load don't count toward the next automatic regrouping, so call `regroup()` once for rows that were never grouped. If two rows share an id, the last one is kept.

Adding faces sometimes regroups the whole library, which takes about a second for 20,000 faces on an M6 Mac. Add faces from a background task.

### One person in many photos

To find every photo of one person when you keep faceprints in your own storage, average a few of their faceprints and compare:

```swift
let noor = Faceprint(averaging: taggedFaces.map(\.faceprint))!   // a selfie or a few tagged photos
let hers = Face.matches(for: noor, in: allFaceprints)              // [Match], most similar first
a.faceprint.isSamePerson(as: b.faceprint)                          // or .strict
```

### Video

On Apple platforms, `faces(inVideoAt:every:)` samples a clip. Add each frame to a library as a photo:

```swift
var library = FaceLibrary()
for try await frame in face.faces(inVideoAt: clipURL, every: 0.5) {
    library.add(frame.faces, photo: frame.photoID(in: clipID))
}
library.people()    // who is in the clip; person.faces gives the frames
```

### Grouping rules

- Faces under 0.5 detector confidence don't start or join groups. Most of them are blurred, dark, turned away, or not faces. They join a person later when they match the person's mean faceprint at cosine 0.5. On our four grouping test sets, this rule raised precision on all four sets and F1 on three.
- Average linkage at cosine distance 0.475 groups the faces. A second pass joins groups whose mean faceprints are within 0.425, so photos of one person over years, in different light, and with and without glasses stay one person.
- Two faces in one photo are never one person.
- A group with fewer than half its faces at 0.5 detector confidence or more is no one, until the user names or confirms one of its faces. Such a group is mostly a few clear statues, cartoons or pets and many unclear faces that match them.
- A group whose mean faceprint is at cosine 0.56 or more to the mean of all faces is no one. Statues, cartoons, pets and masks gather there. Its faces stay out of people until the user names or confirms one of them.
- A person the user named, merged or corrected keeps those faces through every regrouping. A face the user took out of a person never returns to that person, and two named people are never merged.
- A suggestion the user turns down with `reject` never comes back for that person. Adding a photo again keeps what the user said about each face found in it again.
- A person keeps the same id as photos are added and the library regroups. The library regroups on its own when the faces added since the last regrouping reach a quarter of the library.
- `.prominent` lists named people and anyone in at least 10 photos taken on at least 3 different days. Family shows up, and the guests of one wedding don't. `.all` lists everyone in at least 2 photos.
- Suggestions are faces at cosine 0.4 or more to a person's mean faceprint, about 1 false suggestion in 100 strangers. A face joins a person without asking at 0.5, about 1 false match in 1,000.

### Cutoffs

| Level | Cosine | Use it for |
| --- | --- | --- |
| `.recommended` | 0.4129 | Albums, search, suggestions: 1 false match in 1,000 pairs of different people |
| `.strict` | 0.5116 | Anything that acts without asking, such as sharing a photo with someone: 1 in 10,000 |

We set both cutoffs on about 7 million pairs of different people from seven public sets, including low resolution, video stills, decades apart, and every skin tone.

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `minimumConfidence` | 0.35 for `Face`, 0.3 for `FaceDetector` | Low enough to keep faces in dim light, on darker skin and in blur. At 0.35, fewer statues, cartoons and animals reach `FaceLibrary`. |
| `minimumSize` | 32 | Faces smaller than this many pixels are too small to recognise and are left out. |
| `maxFaces` | 20 | The most confident faces are kept. |

In Swift the options are `FaceDetector.Options`, which `Face` also takes as `Face.Options`, with `.recognition` (0.35) as its default.

### Detection accuracy

| Test set | Metric | Core ML | LiteRT |
| --- | --- | ---: | ---: |
| Open Images faces, upright | AP50 | 0.8601 | 0.8598 |
| Open Images faces, turned 90, 180 or 270 degrees | AP50 | 0.80 | 0.80 |
| WIDER Face val | AP easy / medium / hard | 0.8903 / 0.8631 / 0.6960 | |

### Files

The SDK downloads these from Hugging Face on first use and caches them. `FaceDetector` and Eye download the detector only.

| File | Size | Contents |
| --- | ---: | --- |
| `face_detect.mlmodelc` | 7.6 MB | The detector for Core ML, every op on the Neural Engine |
| `face.mlmodelc` | 18 MB | The embedder for Core ML, every op on the Neural Engine |
| `face_detect.tflite` | 15 MB | The detector for LiteRT: Android, Linux, Windows, the browser and Node |
| `face.tflite` | 37 MB | The embedder for LiteRT |

In the browser, a `modelBaseUrl` serves `face_detect.tflite` and `face.tflite`, or `face_detect.tflite` alone for `FaceDetector`.

### Speed

Milliseconds per photo, the median of 50 to 100 runs after two warm-up runs: `FaceDetector`, then `Face` (detection and a faceprint per face), on a 900 x 420 photo with two faces and on the same photo scaled to 12 MP. The last column is how long a `FaceLibrary` takes to add 20,000 faces one photo at a time and group them.

| Device | Runtime | `FaceDetector` | `Face` | `Face`, 12 MP | 20,000 faces grouped |
| --- | --- | ---: | ---: | ---: | ---: |
| Mac mini, M6, macOS 27 | Core ML | 4.0 | 5.8 | 11.6 | 2.3 s |
| Mac Studio, M3 Ultra, macOS 27 | Core ML | 10.5 | 13.0 | 18.3 | 2.9 s |
| MacBook Pro, M1, macOS 26 | Core ML | 13.0 | 16.0 | 33.3 | 5.1 s |
| AMD Ryzen 7 255, Ubuntu 26.04 | LiteRT, CPU | 64 | 77 | 90 | 22 s |
| Nothing A001T, MediaTek MT6878, Android 16 | LiteRT, GPU (OpenCL) | 173 | 220 | 317 | 3 min 22 s |
| Chrome 151 on the Mac mini, M6 | LiteRT.js, WebGPU | 21 | 28 | 102 | 1 min 49 s |

On Apple platforms the first `Face` call after a download takes a few seconds longer, while Core ML compiles the models for the device.

### Limits

Faceprints from different embedders don't compare: `isSamePerson`, `matches` and `FaceLibrary` never match across them. `Faceprint.model` names the embedder (`face-1`). When a new embedder ships, run the photos again.

Face doesn't estimate age, gender, emotion or liveness. Face finds the people a user already has in their own photos.

<!-- model-footer:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

## Citation

```bibtex
@software{face_2026,
  title  = {Face: On-device face matching across a photo library or through a video},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/face},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
<!-- model-footer:end -->
