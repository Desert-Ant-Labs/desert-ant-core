<!-- model:start -->
# Uhm

Find and remove every filler word.

On-device filler-word detection: frame-precise "uh"/"um"/"hmm" spans.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS |
| **Languages** | 5 |
| **Weights** | [v1.1.0](https://huggingface.co/desert-ant-labs/uhm) |
| **Demo** | https://desertant.com/models/uhm/ |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.6.0")
```

Then add the `Uhm` product to your target.
<!-- model:end -->

## Usage

Uhm runs on Apple platforms only. Create one `Uhm` instance and reuse it. The SDK loads the model the first time you use it, or earlier if you call `download`.

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

Uhm accepts any audio format AVFoundation can read. The SDK decodes the audio to 16kHz mono. Use `analyze(audioURL:)` for a file URL, `analyze(bytes:)` for audio in memory, and `analyze(samples:sampleRate:)` for raw PCM.

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

### Downloading the model

The SDK downloads the weights from Hugging Face on first use and caches them. See [model downloads and caching](../../README.md#model-downloads-and-caching).

## Files

| File | Format | Size | Use |
|---|---|---:|---|
| `uhm.mlmodelc/` | Core ML fp16 (compiled) | 45MB | iOS and macOS, on device |
| `uhm-web-fp16.onnx` | ONNX fp16 | 51MB | Browser, server, Python (`onnxruntime`) |
| `uhm.onnx` | ONNX fp32 | 98MB | Unquantized reference |

## Inputs and outputs

- Uhm reads 16kHz mono audio, in windows of up to 30s.
- Uhm outputs a softmax over 6 classes for each 20ms frame.
- The class indices are `0 = not_filler, 1 = uh, 2 = um, 3 = hmm, 4 = and, 5 = other`.

The Core ML input shape is `(30, 1, 1, 16080)` float16: the 30s window, pre-cut into 30 overlapping tiles. The Core ML output shape is `(1, 6, 1, 1499)` float16. The SDK builds the tiled layout for you. The Neural Engine caps every tensor axis at 16384, and the tiled layout lets the whole model run on the Neural Engine. The Core ML model requires iOS 17 or macOS 14 or newer.

The ONNX files keep the plain shapes, `(1, 480000)` float32 input and `(1, 1499, 6)` output, because the tiled layout runs slower on a GPU.

## Performance

We measured warm runs of the published fp16 Core ML model on Apple devices, with the model load excluded:

| Device | Realtime factor |
|---|---:|
| iPhone 17 Pro | 296x |
| iPhone 15 Pro | 169x |
| iPad Pro M4 | 279x |

The realtime factor is the audio duration divided by the time `analyze` takes.

We measured the table on the previous export. The current export runs every operation on the Neural Engine. On an M1, the current export runs 1.6x faster, at 188x end to end against 115x. We haven't measured the current export on the devices in the table yet.

## Limits

- Uhm is trained on English. Uhm detects fillers in other languages by acoustic transfer, and we haven't measured that against per-language ground truth.
- Uhm works best on podcast, meeting, and talking-head audio. Heavy background music, laughter, and overlapping speakers lower the detection quality.
- The type labels (`uh`, `um`, `hmm`, `and`, `other`) are less reliable than the filler detection. Trust whether a span is a filler more than its type.

## Built on

- Base architecture and pretrained weights: [`ntu-spml/distilhubert`](https://huggingface.co/ntu-spml/distilhubert), a distilled variant of [`facebook/hubert-base-ls960`](https://huggingface.co/facebook/hubert-base-ls960). Apache 2.0.
- Public fine-tuning audio: [AMI Meeting Corpus](https://huggingface.co/datasets/edinburghcstr/ami) (`edinburghcstr/ami`, IHM split). CC BY 4.0, Edinburgh CSTR.
- Internal video content created by the Desert Ant Labs team.

## License

Uhm is available under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Most apps can use Uhm for free. At scale, you need a commercial license. The link has the full terms. For licensing, email <licensing@desertant.com>.
