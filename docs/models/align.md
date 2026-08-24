<!-- model:start -->
# Align

Timestamps that land on the word.

Word-timestamp refinement for Apple's SpeechAnalyzer pipeline.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS |
| **Weights** | [main](https://huggingface.co/desert-ant-labs/align) |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.0.0")
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
| `coarse.pt` | PyTorch checkpoint | ~0.5 MB | Coarse-stage weights (for retraining / other runtimes) |
| `fine.pt` | PyTorch checkpoint | ~0.5 MB | Fine-stage weights (for retraining / other runtimes) |

The compiled `.mlmodelc` stages, `mel_filters.bin`, `calibrator.bin`, and `refiner_config.json`
are exactly what the Swift SDK bundles. The `.pt` checkpoints are the training-run weights.

## Architecture

A two-stage coarse-to-fine cascade over a log-mel spectrogram, refining one boundary at a time:

- **Frontend**: an Accelerate/vDSP log-mel spectrogram of the same audio Apple transcribes.
- **Coarse stage**: a compact convolutional model searches a 2.4 s context around Apple's
  proposed boundary and predicts a distribution over frames.
- **Fine stage**: a second model re-searches a 0.8 s crop recentered on the coarse prediction
  for a tighter estimate.
- **Lexical conditioning**: UTF-8 byte features of the neighboring words plus a language id let
  a single model cover all nine languages.
- **Calibrator**: a small gradient-boosted-tree policy maps coarse/fine uncertainty features to
  a final correction, fit only on the validation split to reduce large regressions.
- **Structural fallback**: boundaries whose correction would be invalid, hit the search-window
  edge, or lack streaming context keep Apple's original timestamp.

Each stage runs fixed batch-16 on CPU + Neural Engine. Total parameters are about 117k per stage.

## Inputs and outputs

- **Input:** mono audio plus Apple's recognized words with their proposed start/end times.
- **Output:** the same words with corrected start/end times, or Apple's original time when a
  correction is not structurally safe.

## Accuracy

Evaluated on the exact Swift runtime and these bundled Core ML models over 223 clean and 210
noisy group-held-out recordings across all nine languages, against forced-alignment references.

| Condition | Apple raw error | Align error | Reduction | Median | Within 50 ms |
|---|---:|---:|---:|---:|---:|
| Clean | 113.5 ms | 44.9 ms | 60% | 28.2 ms | 75.1% |
| Noisy | 124.4 ms | 50.1 ms | 60% | 32.0 ms | 69.4% |

Error is mean absolute distance from the reference boundary. Align roughly halves Apple's typical
error and removes most of its large mistakes.

## Languages

English, Spanish, French, Italian, Portuguese, German, Japanese, Korean, and Chinese. A locale
outside this set is passed through unchanged.

## Limitations

- References are machine forced-alignment estimates, not human annotations, so the figures show a
  large, consistent reduction of Apple's timing error rather than sample-accurate ground truth.
- A learned correction is not guaranteed to improve every boundary; the structural fallback keeps
  Apple's timestamp when a correction looks unsafe but cannot catch every plausible-looking error.
- English, Italian, Japanese, and Korean are the weakest languages under the current reference
  convention.

## Built on

- [FLEURS](https://huggingface.co/datasets/google/fleurs) (CC BY 4.0): multilingual training audio.
- [Qwen3-ForcedAligner-0.6B](https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B) (Apache-2.0):
  primary word-boundary references for all nine languages.
- OWSM-CTC v4 1B (CC BY 4.0): gross alignment-outlier check where validation agreement is stable.
- Genuine Apple `SpeechAnalyzer` proposals collected on macOS 26.

See [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/align/blob/main/THIRD_PARTY_NOTICES.md). None of these systems are redistributed here.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for most apps;
a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.
