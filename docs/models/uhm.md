<!-- model:start -->
# Uhm

Find and remove every filler word.

On-device filler-word detection: frame-precise "uh"/"um"/"hmm" spans.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Languages** | 5 |
| **Weights** | [v1.2.0](https://huggingface.co/desert-ant-labs/uhm/tree/v1.2.0) |
| **Demo** | https://desertant.com/models/uhm/ |
<!-- model:end -->

Find every "uh", "um" and "hmm" in an audio file, down to 20ms. Uhm runs on device, doesn't need a transcript, and is trained on English with acoustic transfer to Spanish, French, German, and Dutch.

## Try it

- **Browser demo:** [`huggingface.co/spaces/desert-ant-labs/uhm-demo`](https://huggingface.co/spaces/desert-ant-labs/uhm-demo). Drop in any audio or video file and get a click-to-seek filler timeline.

<!-- model-install:start -->
## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.3.0")
```

Then add the `Uhm` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:uhm:4.3.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/uhm @litertjs/core   # browser
npm i @desert-ant-labs/uhm                  # Node, prebuilt native core
```
<!-- model-install:end -->

## Usage

Create one `Uhm` instance and reuse it. The SDK loads the model the first time you use it, or earlier if you call `download`.

### Swift

```swift
import Uhm

let uhm = Uhm()
let result = try await uhm.analyze(audioPath: "interview.m4a")

for filler in result.fillers {
    print(filler.start, filler.end, filler.confidence)   // seconds, seconds, 0...1
}
result.audioDuration
result.phaseTimings.inferenceSec                         // seconds spent running the model
```

On Apple platforms, Uhm accepts any audio format AVFoundation can read. The SDK decodes the audio to 16kHz mono. Use `analyze(audioURL:)` for a file URL, `analyze(bytes:)` for audio in memory, and `analyze(samples:sampleRate:)` for raw PCM.

`Options` sets the balance between recall and precision. `Options` also sets the shortest span Uhm keeps, 0.12s by default. `bias` picks the confidence threshold. Use `.precision` (0.75) when you cut fillers automatically. `.balanced` (0.65) is the default. Use `.recall` (0.50) when you would rather review and confirm each filler than miss one.

```swift
let options = Uhm.Options(bias: .precision, minDurationSec: 0.08)
let result = try await uhm.analyze(audioPath: "interview.m4a", options: options)

result.fillers.first?.type      // .uh, .um, .hmm, .and, .other
```

The SDK labels each filler with its type by default. The type labeler runs on Apple's SoundAnalysis framework. Pass `includeTypes: false` to skip the labeler when you only need to know where the fillers are.

Pass a `progressHandler` to track a long file. Cancel the enclosing task to stop the run:

```swift
let result = try await uhm.analyze(audioPath: path) { fraction in
    print("\(Int(fraction * 100))%")
}
```

### Kotlin

```kotlin
val uhm = Uhm(context)
val result = uhm.detect(samples, 16_000.0, Options(bias = Bias.PRECISION))

for (f in result.fillers) println("${f.start} ${f.end} ${f.confidence}")
uhm.close()
```

### JavaScript

The default import is the browser build, which runs on WebAssembly and LiteRT.js. For inference in Node, import the `/native` subpath, which runs a prebuilt native core.

```js
import { Uhm } from "@desert-ant-labs/uhm";           // browser
// import { Uhm } from "@desert-ant-labs/uhm/native"; // server-side Node

const uhm = await Uhm.load();
const result = await uhm.detect(samples, 16000);

for (const f of result.fillers) console.log(f.start, f.end, f.confidence);
result.audioDuration
uhm.dispose();
```

`samples` is mono `Float32Array` audio at any sample rate. `bias` takes the same presets as Swift: `"precision"`, `"balanced"` (the default), and `"recall"`. Outside Apple platforms, every filler has `type: null` in JavaScript and Kotlin, because the type labeler runs on Apple's SoundAnalysis framework.

### Cutting fillers without clipping words

To cut fillers out of a recording, pass your transcript's words with the audio. Uhm returns the words adjusted to the fillers. Uhm drops a word that the recognizer wrote for the filler itself, trims a word that runs into a filler, and splits a word that contains a filler. Cut at the returned word ranges, and every real word keeps its audio.

```js
const result = await uhm.detect(samples, 16000, {
  bias: "precision",
  words: transcript.words,                            // [{ start, end, text }]
});
result.words
```

In Kotlin, pass `words` to `detect`. In Swift, `Uhm.reconcileWords(_:fillers:)` applies the same rules.

### Downloading the model

The SDK downloads the weights from Hugging Face on first use and caches them. See [model downloads and caching](../../README.md#model-downloads-and-caching).

## Files

| File | Format | Size | Use |
|---|---|---:|---|
| `uhm.mlmodelc/` | Core ML fp16 (compiled) | 45MB | iOS and macOS, on device |
| `uhm.aimodel/` | Core AI | 45MB | iOS 27 and macOS 27, where the Swift SDK prefers it over Core ML |
| `uhm.tflite` | LiteRT (int8 weight-only) | 24MB | Android, Linux, Windows and the browser. Matches `uhm.onnx` at 99.7-100% per-frame argmax. |
| `uhm-web-fp16.onnx` | ONNX fp16 | 51MB | Browser, server, Python (`onnxruntime`) |
| `uhm.onnx` | ONNX fp32 | 98MB | Unquantized reference |

## Inputs and outputs

- Uhm reads 16kHz mono audio, in windows of up to 30s.
- Uhm outputs a softmax over 6 classes for each 20ms frame.
- The class indices are `0 = not_filler, 1 = uh, 2 = um, 3 = hmm, 4 = and, 5 = other`.

The Core ML input shape is `(30, 1, 1, 16080)` float16: the 30s window, pre-cut into 30 overlapping tiles. The Core ML output shape is `(1, 6, 1, 1499)` float16. The SDK builds the tiled layout for you. The Neural Engine caps every tensor axis at 16384, and the tiled layout lets the whole model run on the Neural Engine. The Core ML model requires iOS 17 or macOS 14 or newer.

The LiteRT and ONNX files keep the plain shapes, `(1, 480000)` float32 input and `(1, 1499, 6)` output, because the tiled layout runs slower on a GPU.

## Performance

We measured warm runs of the published fp16 Core ML model on Apple devices, with the model load excluded:

| Device | Realtime factor |
|---|---:|
| iPhone 17 Pro | 296x |
| iPhone 15 Pro | 169x |
| iPad Pro M4 | 279x |

The realtime factor is the audio duration divided by the time `analyze` takes.

We measured the table on the previous export. The current export runs every operation on the Neural Engine. On an M1, the current export runs 1.6x faster, at 188x end to end against 115x. We haven't measured the current export on the devices in the table yet.

In the browser, Uhm runs `uhm.tflite` through LiteRT.js on one thread. On an M4 Mac in Chromium, 5 minutes of audio take 81s, a realtime factor of 3.7x. Core ML on the same Mac runs at 272x.

### LiteRT against Core ML

On Android, Linux, Windows, and in the browser, Uhm runs `uhm.tflite` instead of the Core ML model. We ran both on three episodes from the [PodcastFillers](https://zenodo.org/records/7121457) test set, 2.1 hours of real podcast audio. The two models agree on 635 of 642 fillers. For those fillers, 95% of start and end times match to within 20ms, and 95% of confidences differ by less than 0.02. Both score the same against the human labels:

| Runtime | Precision | Recall | F1 |
|---|---:|---:|---:|
| Core ML, macOS | 0.80 | 0.74 | 0.77 |
| LiteRT, browser | 0.80 | 0.74 | 0.77 |

A detected filler counts as correct when the filler starts within 0.2s of a labeled filler.

## Limitations

- Uhm is trained on English. Uhm detects fillers in other languages by acoustic transfer, and we haven't measured that against per-language ground truth.
- Uhm works best on podcast, meeting, and talking-head audio. Heavy background music, laughter, and overlapping speakers lower the detection quality.
- The type labels (`uh`, `um`, `hmm`, `and`, `other`) are less reliable than the filler detection. Trust whether a span is a filler more than its type.

## Built on

- Base architecture and pretrained weights: [`ntu-spml/distilhubert`](https://huggingface.co/ntu-spml/distilhubert), a distilled variant of [`facebook/hubert-base-ls960`](https://huggingface.co/facebook/hubert-base-ls960). Apache 2.0.
- Public fine-tuning audio: [AMI Meeting Corpus](https://huggingface.co/datasets/edinburghcstr/ami) (`edinburghcstr/ami`, IHM split). CC BY 4.0, Edinburgh CSTR.
- Internal video content created by the Desert Ant Labs team.

<!-- model-footer:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

Third-party notices for the weights: [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/uhm/blob/main/THIRD_PARTY_NOTICES.md).

## Citation

```bibtex
@software{uhm_2026,
  title  = {Uhm: On-device filler-word detection: frame-precise "uh"/"um"/"hmm" spans},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/uhm},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
<!-- model-footer:end -->
