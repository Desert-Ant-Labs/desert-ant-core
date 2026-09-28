<!-- model:start -->
# Align

Accurate word timestamps for any transcript.

Word-timestamp refinement for any transcript, on device.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Linux, Windows, Node |
| **Languages** | 9 |
| **Weights** | [v1.1.0](https://huggingface.co/desert-ant-labs/align) |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.5.0")
```

Then add the `Align` product to your target.

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/align
```
<!-- model:end -->

## Changes in this release

- `refine` is `async` and takes `languageCode`. `refine` works on the words of any transcript, not only on `SpeechAnalyzer` output.
- The handle is `Align`. `SpeechTimestampRefiner` remains as a deprecated alias for the name only. A 3.x call site doesn't compile through the alias, because `Align` has no `locale:` initializer and both `refine` and `isSupported` changed shape.
- Streaming callers move to `StreamingRefiner`. `StreamingRefiner` wraps an `Align` and keeps the `SpeechAnalyzer` integration. `SpeechTimestampRefiner(locale:)` no longer compiles.
- On Apple platforms, corrected timestamps change at this release. We fixed a bug in the Core ML runtime's audio features, which scaled power by 4 before the log.
- Align now runs on Linux, Windows and Node, through LiteRT.
- The npm package runs only in Node. In the browser, `load()` throws an error that tells you to import `@desert-ant-labs/align/native` on a server instead. See [Limitations](#limitations) for why.
- Three more changes break 3.x code. `isSupported` is now an `async throws -> Bool` method that takes a language code, where it used to be a property. The offline handle no longer has `reset()`. `AlignResourceError` is removed.

## Usage

Align corrects the word timestamps of any transcript against its audio. On Apple platforms, Align also attaches to `SpeechAnalyzer` (iOS 26 and later) through `StreamingRefiner`.

### Swift

```swift
import Align

let align = Align()
guard try await align.isSupported(languageCode: "en") else { return words }
let fixed = try await align.refine(words, audio: samples, sampleRate: 16_000, languageCode: "en")
```

### SpeechAnalyzer (Apple)

Add `StreamingRefiner` to Apple's SpeechAnalyzer pipeline. The refiner records the audio you pass to SpeechAnalyzer and corrects the word timestamps in the results:

```swift
import Align

let refiner = StreamingRefiner(locale: locale)

try await analyzer.start(inputSequence: inputs.recordingAudio(for: refiner))

for try await result in transcriber.results.refiningTimestamps(with: refiner) {
    result.text     // corrected word-level audioTimeRange attributes
    result.words    // [WordTiming]: text, start, end, refined
}
```

The refiner corrects only finalized results. Volatile results come through unchanged.

If your audio arrives in callbacks, call `analyzerInput` on each buffer. `analyzerInput` records the buffer for the refiner and returns the `AnalyzerInput` to pass to SpeechAnalyzer:

```swift
let input = try await refiner.analyzerInput(buffer)   // buffers the audio, returns Apple's input
```

If SpeechAnalyzer reads from a file, create the refiner with the same `AVAudioFile`. The refiner reads the file through its own handle, so SpeechAnalyzer's read position doesn't change:

```swift
let refiner = try await StreamingRefiner(locale: locale, audioFile: file)
```

### JavaScript

The `/native` subpath runs inference in plain Node. The subpath ships prebuilt for linux-x64, linux-arm64 and darwin-arm64.

```ts
import { Align } from "@desert-ant-labs/align/native";

const align = await Align.load();
const fixed = await align.refine(samples, 16000, words, { language: "en", deviceId: userId });
align.dispose();
```

### Unsupported locales

Align supports the nine [languages](#languages) below. Check the language before you build the pipeline. For an unsupported language, `refine` returns the words unchanged and doesn't throw:

```swift
guard try await align.isSupported(languageCode: "sv") else { /* use the original timestamps as-is */ }
```

To check the language a `StreamingRefiner` was created with, call `try await refiner.isSupported()`. In JavaScript, `Align.isSupported(language)` is a synchronous check with the same meaning.

`refine` also keeps the original timestamp for a word whose correction lands at the edge of the window Align searches, or whose corrected range would end before it starts. When streaming, `refine` does the same for a word whose forward context isn't buffered yet. These fallbacks check structure and don't check accuracy. A correction that looks plausible but is wrong still lands. If a model fails to run, `refine` throws an error and doesn't fall back. See [Limitations](#limitations).

Align checks the input before doing any work, whatever the language. Every `start` and `end` must be finite and from -1 to 10,000,000 seconds. The sample rate must be finite and positive. The audio must not be empty. Audio at a rate other than 16kHz must be shorter than 37 hours. Swift throws `AlignError.invalidInput`, naming the word. JavaScript rejects with a `RangeError`. A word more than 1.2s past the end of the audio has nothing to refine against, so the word keeps its input times with `refined` false.

### Loading the model

The SDK downloads the weights from Hugging Face on first use and caches them. To download them earlier, for example during onboarding, or to ship them yourself, see [model downloads and caching](../../README.md#model-downloads-and-caching).

```swift
let align = Align()
if !align.isDownloaded() {
    try await align.download { fraction in print("\(Int(fraction * 100))%") }
}

let offline = Align(directory: myModelDirectory)   // uses the files as they are, downloads nothing
```

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `align-coarse.mlmodelc` | Compiled Core ML (FP16) | 0.3MB | Coarse stage |
| `align-fine.mlmodelc` | Compiled Core ML (FP16) | 0.3MB | Fine stage |
| `align-coarse.tflite` | LiteRT (FP32) | 0.5MB | Coarse stage |
| `align-fine.tflite` | LiteRT (FP32) | 0.5MB | Fine stage |
| `mel_filters.bin` | Float32 filter bank | 40KB | Log-mel filter bank the runtime frontend needs |
| `calibrator.bin` | Gradient-boosted trees | 70KB | Correction calibrator |
| `refiner_config.json` | JSON | tiny | Runtime config |

On Apple platforms, the Swift SDK downloads the compiled `.mlmodelc` stages, `mel_filters.bin`, `calibrator.bin` and `refiner_config.json`. On Linux, Windows and Node, the `.tflite` pair replaces the two `.mlmodelc` directories.

## Inputs and outputs

- You pass mono audio and the words of any transcript, with their proposed start and end times.
- You get the same words back with corrected start and end times. A word keeps its original time when a correction isn't structurally safe.

## Accuracy

On clean audio, averaged over the nine languages, Align cuts the timing error of the input timestamps by two-thirds. Per language, the cut ranges from a third to over three quarters. The cut is smaller on noisy audio.

We score both runtimes on `gold-en-us`, a set of 258 boundaries corrected by hand against the waveform. On Apple platforms, the Core ML runtime's mean boundary error on that set is 44.8ms (darwin-arm64, 2026-09-21). The training-time reference scores 45.0ms. The input timestamps, before Align, score 100.8ms. The LiteRT runtime matches the training-time reference to five significant figures. These are averages over one English set, and a single boundary can be further off.

The clean, noisy, and per-language figures come from the training-time reference, not from an on-device runtime. The on-device Core ML figures from v1.0.0 no longer apply, because the Core ML runtime's audio features changed at this release. The [model card](https://huggingface.co/desert-ant-labs/align) has the same per-condition figures and names the three weakest languages.

## Languages

English, Spanish, French, Italian, Portuguese, German, Japanese, Korean, and Chinese. Align passes a locale outside this set through unchanged.

## Limitations

- The averaged figures compare against a forced aligner, not against boundaries marked by hand. The figures show that Align cuts the timing error of the input timestamps. They don't show how close Align gets to the true boundary.
- Align doesn't improve every boundary. The structural fallback keeps the original timestamp when a correction looks unsafe. The fallback can't catch every plausible-looking error.
- Japanese, Korean, and Chinese were the weakest languages before v1.0.0. Align now improves their input timestamps by 33%, 55%, and 51%.
- Numbers are the weakest remaining case. On a small sample, refinement moved digit boundaries further from the reference than leaving them alone. Treat spoken numbers as unimproved until a larger sample settles the question.
- The Core ML and LiteRT runtimes can disagree by 10ms on the same audio. We test both runtimes against Core ML's recorded output on synthetic audio. Core ML on the CPU matches that output (0.0ms, against a 25ms tolerance). LiteRT drifts 10.4ms (linux-arm64, 2026-09-17). Don't expect the two runtimes to agree to below a millisecond.
- Align has no browser build. Align runs two models in sequence, and our WebAssembly build loads only one model.
- Align has no Android SDK.

## License

Align is available under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Most apps can use Align for free. At scale, you need a commercial license. The link has the full terms. For licensing, email <licensing@desertant.com>.
