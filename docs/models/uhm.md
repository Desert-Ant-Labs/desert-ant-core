<!-- model:start -->
# Uhm

An hour of audio in twelve seconds.

On-device filler-word detection: frame-precise "uh"/"um"/"hmm" spans.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS |
| **Languages** | 5 |
| **Weights** | [612592c](https://huggingface.co/desert-ant-labs/uhm) |
| **Demo** | https://desertant.com/models/uhm/ |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.1.0")
```

Then add the `Uhm` product to your target.
<!-- model:end -->

## Usage

Apple only today. Create one detector and reuse it: the model loads on first
use, or earlier if you call `download`.

### Swift

```swift
import Uhm

let uhm = Uhm()
let result = try await uhm.analyze(audioPath: "interview.m4a")

for filler in result.fillers {
    print(filler.start, filler.end, filler.confidence)   // seconds, seconds, 0...1
}
result.audioDuration
result.phaseTimings.inferenceSec                         // where the time went
```

Any format the platform decoder can read is accepted; audio is decoded to
16 kHz mono internally. `analyze(audioURL:)`, `analyze(bytes:)` for in-memory
audio, and `analyze(samples:sampleRate:)` for raw PCM are the other entry
points.

`Options` trades recall against precision and drops spans that are too short.
`bias` is the threshold preset: `.precision` (0.75) for automatic cuts,
`.balanced` (0.65) by default, `.recall` (0.50) when you would rather review and
confirm than miss one.

```swift
let options = Uhm.Options(bias: .precision, minDurationSec: 0.08)
let result = try await uhm.analyze(audioPath: "interview.m4a", options: options)

result.fillers.first?.type      // .uh, .um, .hmm, .and, .other
```

The type labeler is on by default and Apple-only; `type` stays nil elsewhere.
Pass `includeTypes: false` to skip it when filler-vs-not spans are enough.

Pass a `progressHandler` to follow a long file, and cancel the enclosing task to
stop the run:

```swift
let result = try await uhm.analyze(audioPath: path) { fraction in
    print("\(Int(fraction * 100))%")
}
```

### Loading the model

The weights are fetched from the Hub on first use and cached. See
[model downloads and caching](../../README.md#model-downloads-and-caching).

## Files

| File | Format | Size | Use |
|---|---|---:|---|
| `uhm.mlmodelc/` | Core ML fp16 (compiled) | ~45 MB | iOS / macOS on-device |
| `uhm-web-fp16.onnx` | ONNX fp16 | ~51 MB | Browser, server, Python (`onnxruntime`) |
| `uhm.onnx` | ONNX fp32 | ~98 MB | Quantization-free reference |

`uhm.mlmodelc/` is a compiled Core ML model directory. The Swift SDK downloads it with the Hugging Face Hub snapshot API, so only changed files are re-fetched on model updates.

The shipped model is a DistilHuBERT fine-tune. It is the smaller and more precise Uhm runtime model; the older HuBERT-base tier is no longer published.

## Inputs and outputs

- **Input:** 16 kHz mono audio, up to 30-second windows.
- **Output:** per-frame softmax over 6 classes, one prediction every 20 ms.
- **Class indices:** `0 = not_filler, 1 = uh, 2 = um, 3 = hmm, 4 = and, 5 = other`.

Core ML input shape `(1, 480000)` float32; output `(1, 1499, 6)`. Requires iOS 17 / macOS 14 or newer.

## Performance

Warm on-device runs on the published fp16 Core ML model:

| Device | Realtime factor |
|---|---:|
| iPhone 17 Pro | ~296× |
| iPhone 15 Pro | ~169× |
| iPad Pro M4 | ~279× |

Realtime factor = audio duration ÷ analyze time; model load excluded.

## Limitations

- Trained on English; non-English performance is by acoustic transfer and has not been measured against per-language ground truth.
- Best on podcast / meeting / talking-head audio. Heavy background music, laughter, or multi-speaker overlap degrades quality.
- Type labels (`uh` / `um` / `hmm` / `and` / `other`) are secondary. Trust filler vs. not-filler more than the specific subtype.

## Built on

- Base architecture and pretrained weights: [`ntu-spml/distilhubert`](https://huggingface.co/ntu-spml/distilhubert), a distilled variant of [`facebook/hubert-base-ls960`](https://huggingface.co/facebook/hubert-base-ls960). Apache 2.0.
- Public fine-tuning audio: [AMI Meeting Corpus](https://huggingface.co/datasets/edinburghcstr/ami) (`edinburghcstr/ami`, IHM split). CC BY 4.0, Edinburgh CSTR.
- Internal video content created by the Desert Ant Labs team.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for
most apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.
