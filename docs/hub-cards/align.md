---
license: other
license_name: desert-ant-labs-source-available-1.0
license_link: https://license.desertant.ai/1.0
language:
- multilingual
tags:
- speech
- word-timestamps
- forced-alignment
- speech-recognition
- on-device
- core-ml
- multilingual
pipeline_tag: automatic-speech-recognition
---

# Align: on-device word-timestamp refinement for Apple SpeechAnalyzer

Corrects the word-level timings that Apple's `SpeechTranscriber` and `SpeechAnalyzer`
return, without replacing them. Align observes the same audio the analyzer already
receives, runs a small Core ML cascade on the CPU and Neural Engine, and returns the
familiar result surface with tightened `audioTimeRange` values. The models are tiny
(**about 0.7 MB** compiled Core ML) and refine a typical result in a few milliseconds
on device.

> Apple: `"world"` 2.61-3.04s  ➜  Align: `"world"` 2.57-2.98s

## Try it

Ships as an Apple SwiftPM package: **[Desert-Ant-Labs/align](https://github.com/Desert-Ant-Labs/align)**.

- **iOS / iPadOS / Mac Catalyst / macOS / tvOS / visionOS:** the Swift SDK (Swift Package
  Manager). It bundles the compiled Core ML models below, so it works fully offline. The
  package adds to apps with low deployment targets; the SpeechAnalyzer refinement APIs are
  gated with `@available` and run on the 26 releases those frameworks require.
- Add one input modifier (`inputs.recordingAudio(for: refiner)`) and one result modifier
  (`transcriber.results.refiningTimestamps(with: refiner)`) to the standard Apple pipeline.

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

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). None of these systems are redistributed here.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.ai/1.0). Free for most apps;
a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.ai>.

## Citation

```bibtex
@software{align_2026,
  title  = {Align: on-device word-timestamp refinement for Apple SpeechAnalyzer},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/align},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.ai>
