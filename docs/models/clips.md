<!-- model:start -->
# Clips

Create short videos and highlight clips.

Short clips and highlights from talking video and audio: podcasts, interviews, meetings. On-device.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Linux, Windows |
| **Weights** | [v0.1.0](https://huggingface.co/desert-ant-labs/clips/tree/v0.1.0) |
<!-- model:end -->

Pass Clips a transcript and get the moments worth cutting into short videos, ranked best first and never overlapping. Clips works on podcasts, interviews and meetings, and nothing is uploaded, so clipping a back catalog costs the same as clipping one video.

The model is 284MB as a single int8 Core ML package on Apple platforms, or two 283MB LiteRT files on Linux and Windows.

Clips carry no title. To write one for each clip, pair Clips with [Title](title.md).

<!-- model-install:start -->
## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.2.2")
```

Then add the `Clips` product to your target.
<!-- model-install:end -->

## Usage

Pass a transcript as one sentence per element, in spoken order. Clips returns the best moments that don't overlap, ranked, so you can cut them into short videos.

### Swift

```swift
import Clips

let clips = Clips()
let moments = try await clips.clips(in: sentences)      // [Clip], best first

for clip in moments {
    print(clip.text, clip.start, clip.end, clip.score)
    print(clip.sentenceIDs)                             // which sentences the clip spans
    print(clip.estimatedDurationSec, clip.percentile)
}
```

For a transcript under three sentences, Clips returns `[]`.

`limit` sets the most clips Clips returns, and also how much work Clips does. Clips builds candidate clips around the `4 × limit` most salient sentences, so a smaller limit means fewer scorer passes. Scorer passes take 60-85% of the runtime:

```swift
let ten = try await clips.clips(in: sentences, limit: 10)   // default is 10
let auto = try await clips.clips(in: sentences, limit: nil) // Clips sets the limit from the duration
```

The result at `limit: 10` is generally not the first ten of the result at `limit: 14`. Clips returns the non-overlapping set of clips with the highest total score, and the best set of ten isn't the best set of fourteen with four removed.

### Writing titles for the clips

To give each clip a title, pass the clips to [Title](title.md):

```swift
let cards = try await titles.cards(for: moments)   // index-aligned with moments
```

### Loading the model

The SDK downloads the weights from Hugging Face on first use and caches them. See [model downloads and caching](../../README.md#model-downloads-and-caching).

## Maximum video length

Clips has no limit on transcript length. The selector reads sentences in batches of 16, and the scorer scores each candidate clip on its own, so a longer video only takes longer. The longest transcript we've run is an 835-sentence podcast.

| Transcript | iPhone 17 Pro | iPhone 15 Pro |
|---|---:|---:|
| 404 sentences, 25 minutes of video, 12 clips | **9.19s** | **10.22s** |
| 57 sentences | 2.23s | |
| per candidate, encoder only | 2.78ms | 3.13ms |

We measured on iPhone at batch 16, with Core ML pinned to `.cpuAndNeuralEngine`.

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `clips.mlmodelc/` | Compiled Core ML, int8 per-channel | 284MB | Multifunction package. Function `select`: `ids`, `mask`, `disc` to `saliency`, `start_p`, `end_p`. Function `score`: `ids`, `mask` to `score` |
| `clips-selector.tflite` | LiteRT, int8 weight-only | 283MB | The selector, for Android, Linux and Windows |
| `clips-scorer.tflite` | LiteRT, int8 weight-only | 283MB | The scorer, for Android, Linux and Windows |
| `clip_tokenizer.bin` | Unigram tokenizer | 4MB | Tokenizer pieces and scores, in the compact binary the runtimes read |
| `clips_meta.json` | JSON | tiny | Graph widths, input roles and feature order a runtime needs |

On Apple platforms both graphs live in one Core ML package with the shared weights stored once.
LiteRT has no equivalent packaging, so the other platforms ship two files.

The selector graph is 128 tokens wide, the scorer 256, both at a fixed batch of 16 sentences. A
sentence longer than 64 tokens is truncated before it reaches the selector.

### Reaching a function in the Core ML package

On Apple platforms, a file path names the package, and the package holds both graphs. To load one graph, set `MLModelConfiguration.functionName` to `select` or `score`. Without the setting, Core ML loads the package's default function without an error, and both halves of the pipeline run the selector.

### LiteRT inputs

The LiteRT graphs take int64 `ids` and `mask` and name their inputs positionally, `args_0` upward. `clips_meta.json` carries the mapping, and the SDK binds the names for you on Linux and Windows. If you drive LiteRT directly, feed `ids` and `mask` in the right order: swapped, the graph still returns finite, plausibly scaled numbers, and the pipeline quietly builds the wrong pool.

## Thresholds

`Clip.score` runs 1 to 5 and is not calibrated between videos. Threshold on `percentile` instead.
An absolute cut at 0.65 returns nothing on 21% of videos, and at 0.75 on half of them. Per-video
95th percentiles range from 0.33 to 0.95.

| percentile cut | clips per video | share of the video covered | use |
|---|---:|---:|---|
| 0.8 | 5.0 | 17% | highlights |
| 0.3 | 32.1 | 74% | auto edit |

## Limitations

- **Clip edges are the weak spot.** A clip can open on a pronoun whose referent was in the
  sentence before it, fuse two topics into one, cut before the payoff lands, or swallow a sponsor
  read.
- **Short videos return few clips.** A two minute transcript comes back with fewer clips than a
  server-side editor would cut, and a transcript under three sentences returns none.
- **The clip limit is a cap, not a quota.** Asking for 10 doesn't mean receiving 10.
- **Selection is sensitive to small score changes.** Candidate spans around one moment score very
  close together, so a different runtime, compute unit or quantization returns a different but
  comparable set.
- **Non-Latin scripts are under-tested.** Our evaluation corpus is overwhelmingly Latin script.
- **Duration is a soft prior.** A clip can come back shorter or longer than a typical Short.
- **Android needs headroom.** The shipped int8 weight-only build peaks at 2136MB resident,
  measured on 6,395 real candidate spans. That fits a high-end phone and not a mid-range one,
  which is why there is no Android SDK yet rather than any limit in the artifact.

## Requirements

On Apple platforms, the Core ML package is specification version 9, so it requires iOS 18, macOS 15, tvOS 18, visionOS 2 or watchOS 11. On Linux and Windows, the SDK runs the two LiteRT files. There is no Android SDK yet: see Limitations.

<!-- model-footer:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

Third-party notices for the weights: [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/clips/blob/main/THIRD_PARTY_NOTICES.md).

## Citation

```bibtex
@software{clips_2026,
  title  = {Clips: Short clips and highlights from talking video and audio: podcasts, interviews, meetings. On-device},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/clips},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
<!-- model-footer:end -->
