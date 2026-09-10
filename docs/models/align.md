<!-- model:start -->
# Align

Accurate word timestamps for any transcript.

Word-timestamp refinement for Apple's SpeechAnalyzer pipeline.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS |
| **Weights** | [v1.0.0](https://huggingface.co/desert-ant-labs/align) |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.1.0")
```

Then add the `Align` product to your target.
<!-- model:end -->

## Usage

Apple only, and specific to Apple's own speech stack: `Align` corrects the word
timestamps `SpeechAnalyzer` produces. It does not transcribe. Requires iOS 26,
macOS 26, tvOS 26 or visionOS 26, which is where `SpeechAnalyzer` lives.

### Swift

Attach the refiner to the standard Speech pipeline. It records the audio going
in and corrects the timestamps coming out:

```swift
import Align

let refiner = try await SpeechTimestampRefiner(locale: locale)

try await analyzer.start(inputSequence: inputs.recordingAudio(for: refiner))

for try await result in transcriber.results.refiningTimestamps(with: refiner) {
    // result.text has corrected word-level audioTimeRange attributes
    result.words          // [WordTiming]: text, start, end, refined
}
```

Volatile results pass through unchanged; finalized results are refined. In a
callback-based audio pipeline, `analyzerInput` does both halves at once:

```swift
let input = refiner.analyzerInput(buffer)      // buffers the audio, returns Apple's input
```

For file input, hand it the `AVAudioFile` the analyzer is reading. A separate
file handle is used, so the file stays positioned for the analyzer:

```swift
let refiner = try await SpeechTimestampRefiner(locale: locale, audioFile: file)
```

### Unsupported locales

Not every locale the transcriber handles is covered by the model. Check before
you build the pipeline; when it is false, `refine` is a passthrough rather than
an error:

```swift
guard refiner.isSupported else { /* use Apple's timestamps as-is */ }
```

The refiner also keeps Apple's original timestamp for any single word whose
correction is structurally invalid, lacks streaming context, or hits the search
edge, so a correction can only improve a word or leave it alone.

### Loading the model

The weights are fetched from the Hub on first use into the managed cache, or
into `directory` when you pass one, and adopted offline afterwards:

```swift
let refiner = try await SpeechTimestampRefiner(locale: locale, directory: myFolder) { progress in
    print(progress)
}
```

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `align_coarse.mlmodelc` | Compiled Core ML (FP16) | ~0.3 MB | Coarse stage: searches a 241-frame (2.4 s) context, fixed batch-16 |
| `align_fine.mlmodelc` | Compiled Core ML (FP16) | ~0.3 MB | Fine stage: searches an 81-frame (0.8 s) crop centered on the coarse prediction |
| `mel_filters.bin` | Float32 filter bank | ~40 KB | Log-mel filter bank the runtime frontend needs |
| `calibrator.bin` | Gradient-boosted trees | ~70 KB | Correction calibrator over coarse/fine uncertainty features |
| `refiner_config.json` | JSON | tiny | Frontend, lexical, and language config the runtime needs |

The compiled `.mlmodelc` stages, `mel_filters.bin`, `calibrator.bin`, and `refiner_config.json`
are exactly what the Swift SDK downloads.

## Inputs and outputs

- **Input:** mono audio plus Apple's recognized words with their proposed start/end times.
- **Output:** the same words with corrected start/end times, or Apple's original time when a
  correction is not structurally safe.

## Accuracy

Measured on v1.0.0 over held-out recordings.

### All nine languages

| Condition | Apple raw error | Align error | Reduction |
|---|---:|---:|---:|
| Clean | 124.2 ms | 43.9 ms | 65% |
| Noisy | 88.3 ms | 33.4 ms | 62% |

Macro-averaged across the nine languages, so a language with more test data cannot carry the
figure on its own.

### Public benchmark, English

A 500-clip sample of each official LibriSpeech `test-clean` and `test-other` split.

| Engine | Split | Raw | Refined | Reduction | Within 50 ms |
|---|---|---:|---:|---:|---|
| Apple SpeechAnalyzer | test-clean | 106.4 ms | 20.2 ms | 81% | 37% to 95% |
| Apple SpeechAnalyzer | test-other | 111.6 ms | 24.8 ms | 78% | 35% to 92% |

The p90 is the figure to read for editing work: on `test-clean` it falls from 230.7 ms to
33.0 ms, roughly one frame of 30fps video. Large errors are what a viewer notices when a
caption slips or a clip cuts mid-word.

### Against a human-annotated set

258 word boundaries across 10 recordings, corrected by hand against the waveform rather than
by another aligner. This is the only figure here not measured against machine references.

| System | Error | Within 50 ms |
|---|---:|---|
| Raw Whisper | 100.8 ms | 43% |
| WhisperX | 53.5 ms | 67% |
| Align | 45.0 ms | 76% |

## Languages

English, Spanish, French, Italian, Portuguese, German, Japanese, Korean, and Chinese. A locale
outside this set is passed through unchanged.

## Limitations

- References are machine forced-alignment estimates, not human annotations, so the figures show a
  large, consistent reduction of Apple's timing error rather than sample-accurate ground truth.
- A learned correction is not guaranteed to improve every boundary; the structural fallback keeps
  Apple's timestamp when a correction looks unsafe but cannot catch every plausible-looking error.
- Japanese, Korean, and Chinese were the weakest languages before v1.0.0. They now improve their
  proposals by 33%, 55%, and 51%.
- Number timings are the weakest remaining case. On a small sample refinement moved digit
  boundaries further from the reference than leaving them alone, so treat spoken numbers as
  unimproved until a larger sample settles it.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for most apps;
a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.
