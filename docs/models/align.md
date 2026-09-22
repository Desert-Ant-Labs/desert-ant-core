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
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.3.1")
```

Then add the `Align` product to your target.

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/align
```
<!-- model:end -->

## Changes in this release

- `refine` is `async` and takes `languageCode`; it works on any transcript's words, not only
  `SpeechAnalyzer` output.
- The handle is `Align`. `SpeechTimestampRefiner` remains as a deprecated alias for the name
  only: `Align` has no `locale:` initializer, and both `refine` and `isSupported` changed
  shape, so a 3.x call site does not compile through it.
- Streaming callers move to `StreamingRefiner`, which wraps an `Align` and keeps the
  `SpeechAnalyzer` integration. `SpeechTimestampRefiner(locale:)` no longer compiles.
- The Apple runtime's log-mel frontend is corrected: it scaled power by 4 before the log.
  On-device results change at this release.
- A LiteRT export adds Linux, Windows and Node.
- The npm package is Node-only, and its default entry refuses in the browser with an
  actionable error. The refiner is a cascade of two graphs, and the WebAssembly host compiles
  one model per module, so there is no browser build.
- Three further changes break source on 3.x callers, separately from the two above:
  `isSupported` is now `async throws -> Bool` and takes a language code rather than being a
  property; `reset()` is no longer on the offline handle; and `AlignResourceError` is removed.

## Usage

Align corrects the word timestamps of any transcript against its audio; on Apple it also
attaches to `SpeechAnalyzer` (iOS 26 and later) through `StreamingRefiner`.

### Swift

```swift
import Align

let align = Align()
guard try await align.isSupported(languageCode: "en") else { return words }
let fixed = try await align.refine(words, audio: samples, sampleRate: 16_000, languageCode: "en")
```

### SpeechAnalyzer (Apple)

Attach the refiner to the standard Speech pipeline. It records the audio going in and
corrects the timestamps coming out:

```swift
import Align

let refiner = StreamingRefiner(locale: locale)

try await analyzer.start(inputSequence: inputs.recordingAudio(for: refiner))

for try await result in transcriber.results.refiningTimestamps(with: refiner) {
    result.text     // corrected word-level audioTimeRange attributes
    result.words    // [WordTiming]: text, start, end, refined
}
```

Volatile results pass through unchanged; finalized results are refined. In a
callback-based audio pipeline, `analyzerInput` does both halves at once:

```swift
let input = try await refiner.analyzerInput(buffer)   // buffers the audio, returns Apple's input
```

For file input, hand it the `AVAudioFile` the analyzer is reading. A separate file handle
is used, so the file stays positioned for the analyzer:

```swift
let refiner = try await StreamingRefiner(locale: locale, audioFile: file)
```

### JavaScript

The `/native` subpath runs inference in plain Node, prebuilt for linux-x64, linux-arm64 and
darwin-arm64.

```ts
import { Align } from "@desert-ant-labs/align/native";

const align = await Align.load();
const fixed = await align.refine(samples, 16000, words, { language: "en", deviceId: userId });
align.dispose();
```

### Unsupported locales

Not every locale is covered by the model. Check before you build the pipeline; when it is
false, `refine` is a passthrough rather than an error:

```swift
guard try await align.isSupported(languageCode: "sv") else { /* use the original timestamps as-is */ }
```

A `StreamingRefiner` checks the language it was created with the same way, with
`try await refiner.isSupported()`. On JavaScript, `Align.isSupported(language)` is a
synchronous check with the same meaning.

`refine` also keeps the original timestamp for any single word whose correction runs into the
search edge, whose corrected range would end before it starts, or, when streaming, whose forward
context is not buffered yet. Those fallbacks are checks on structure, not on accuracy: a
correction that looks plausible but is wrong still lands. A stage that fails outright throws
rather than falling back. See Limitations.

### Loading the model

The weights are fetched from the Hub on first use and cached. To fetch them earlier, for
example during onboarding, or to ship them yourself, see
[model downloads and caching](../../README.md#model-downloads-and-caching).

```swift
let align = Align()
if !align.isDownloaded() {
    try await align.download { fraction in print("\(Int(fraction * 100))%") }
}

let offline = Align(directory: myModelDirectory)   // adopted as-is, nothing downloaded
```

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `align-coarse.mlmodelc` | Compiled Core ML (FP16) | ~0.3 MB | Coarse stage |
| `align-fine.mlmodelc` | Compiled Core ML (FP16) | ~0.3 MB | Fine stage |
| `align-coarse.tflite` | LiteRT (FP32) | ~0.5 MB | Coarse stage |
| `align-fine.tflite` | LiteRT (FP32) | ~0.5 MB | Fine stage |
| `mel_filters.bin` | Float32 filter bank | ~40 KB | Log-mel filter bank the runtime frontend needs |
| `calibrator.bin` | Gradient-boosted trees | ~70 KB | Correction calibrator |
| `refiner_config.json` | JSON | tiny | Runtime config |

The compiled `.mlmodelc` stages, `mel_filters.bin`, `calibrator.bin`, and `refiner_config.json`
are what the Swift SDK downloads on Apple; the `.tflite` pair replaces the two `.mlmodelc`
directories on Linux, Windows and Node.

## Inputs and outputs

- **Input:** mono audio plus any transcript's words with their proposed start/end times.
- **Output:** the same words with corrected start/end times, or the original time when a
  correction is not structurally safe.

## Accuracy

On the clean condition, macro-averaged over the nine languages, Align cuts the proposer's raw
timing error by roughly two-thirds. Per language it ranges from a third to over three quarters,
and the noisy condition is lower. Both runtimes are scored on `gold-en-us`, the 258-boundary set
corrected by hand against the waveform. There the on-device Core ML runtime's corpus mean boundary
error is 44.8 ms (darwin-arm64, 2026-09-21), within 0.2 ms of the same checkpoint through the
training-time frontend (45.0) and less than half the proposer's 100.8 ms, and the LiteRT export's
corpus mean boundary error on that set matches the training-time reference to five significant
figures. That is one corpus average in one language, not a per-boundary guarantee. The
per-condition and per-language figures on this page are the training-side measurement; the Apple
runtime's frontend changed at this release, so on-device Core ML numbers differ from v1.0.0's and
are not carried over from it. The same per-condition figures are on the
[model card](https://huggingface.co/desert-ant-labs/align), which also names the three
weakest languages.

## Languages

English, Spanish, French, Italian, Portuguese, German, Japanese, Korean, and Chinese. A locale
outside this set is passed through unchanged.

## Limitations

- The macro-averaged figures are measured against machine forced-alignment estimates, not human
  annotations, so they show a large, consistent reduction of the proposer's timing error rather
  than sample-accurate ground truth.
- A learned correction is not guaranteed to improve every boundary; the structural fallback keeps
  the original timestamp when a correction looks unsafe but cannot catch every plausible-looking error.
- Japanese, Korean, and Chinese were the weakest languages before v1.0.0. They now improve their
  proposals by 33%, 55%, and 51%.
- Number timings are the weakest remaining case. On a small sample refinement moved digit
  boundaries further from the reference than leaving them alone, so treat spoken numbers as
  unimproved until a larger sample settles it.
- The LiteRT export is a third numeric path alongside Core ML and the training-time reference. The
  parity fixture is Core ML's own recorded output on synthetic audio: Core ML on the CPU
  reproduces it where it was measured (0.0 ms, against a 25 ms tolerance) while LiteRT drifts
  10.4 ms from it (linux-arm64, 2026-09-17). Treat the two runtimes as able to disagree by around
  10 ms on the same audio, not as agreeing to sub-millisecond.
- No browser build: the cascade is two graphs, and the WebAssembly host compiles one model per
  module.
- No Android SDK.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for most apps;
a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.
