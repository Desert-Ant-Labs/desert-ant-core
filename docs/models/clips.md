<!-- model:start -->
# Clips

Create short videos and highlight clips.

Short clips and highlights from talking video and audio: podcasts, interviews, meetings. On-device.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Linux, Windows |
| **Weights** | [v0.1.0](https://huggingface.co/desert-ant-labs/clips) |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.6.0")
```

Then add the `Clips` product to your target.
<!-- model:end -->

## Usage

Clips runs on Apple platforms. Pass a transcript as one sentence per element, in spoken order. Clips returns the best moments that don't overlap, ranked, so you can cut them into short videos.

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

| File | Format | Contents |
|---|---|---|
| `clips.mlmodelc/` | Compiled Core ML, int8 | Multifunction package. Function `select`: `ids`, `mask`, `disc` → `saliency`, `start_p`, `end_p`. Function `score`: `ids`, `mask` → `score` |
| `clips-selector.tflite` | LiteRT, int8 weight-only | The selector, for Android, Linux and Windows. The SDK can't run this file yet. |
| `clips-scorer.tflite` | LiteRT, int8 weight-only | The scorer, for Android, Linux and Windows. The SDK can't run this file yet. |
| `clip_tokenizer.bin` | Unigram tokenizer | Tokenizer pieces and scores, in the compact binary the runtime reads |
| `clips_meta.json` | JSON | Graph widths, input roles and feature order a runtime needs |

### Reaching a function in the Core ML package

On Apple platforms, a file path names the package, and the package holds both graphs. To load one graph, set `MLModelConfiguration.functionName` to `select` or `score`. Without the setting, Core ML loads the package's default function without an error, and both halves of the pipeline run the selector.

### Graph widths

The selector runs at 128 tokens and the scorer at 256. Both run at a fixed batch of 16 sentences.

The SDK truncates each sentence to 64 tokens before the selector. The 64-token cut is separate from the selector's 128-token graph width.

## Status

Clips is in internal testing. We haven't published quality figures for Clips yet.

> ### The `.tflite` files don't work with the Desert Ant SDK yet. Don't build on them.
>
> The SDK's LiteRT backend can't drive the files:
>
> - The graphs name their inputs `args_0`, `args_1`, `args_2` and their outputs `output_0` to `output_2`. The SDK asks for `ids`, `mask`, `disc` and `saliency`, `start_p`, `end_p`. The SDK has no mapping between the names, so the first call fails.
> - The graphs take int64 ids and mask. The SDK builds int32.
> - The scorer is 256 wide. The SDK's LiteRT backend can't report a width, so the SDK falls back to 128.
>
> If you drive LiteRT directly, you can use the files: `clips_meta.json` has the shapes and output order. The SDK can't run Clips from the files on Android, Linux or Windows today.
>
> The LiteRT export also uses too much memory for Android. We measured 2.1GB peak RSS against a 1.6GB Android budget.

We generated clips from the Core ML package and judged them. Nobody has read a clip from the LiteRT files, on any platform.

## Requirements

The Core ML package is specification version 9, so the package requires iOS 18, macOS 15, tvOS 18, visionOS 2 or watchOS 11. Reaching either graph needs `MLModelConfiguration.functionName` set to `select` or `score`.

## Limits

- Clips returns markedly fewer clips than expected for a short transcript. If your product needs a set number of clips from a two-minute video, measure before relying on Clips.
- Clips returns some weak clips, most often on podcast-length input. Clips has no confidence score to filter on yet. `Clip.score` ranks clips within one video and isn't calibrated across videos.
- `limit` sets a maximum number of clips. Asking for 10 doesn't mean receiving 10.
- Small score changes can change which clips Clips selects. Candidate spans around one moment score very close together. A different runtime, compute unit or quantization can return a different set of comparable clips. Don't treat exact span equality between two builds as a correctness check.
- Clips is under-tested on non-Latin scripts. The evaluation corpus is overwhelmingly Latin-script.
- Clips doesn't hold clips to a fixed duration. Duration is a soft prior, so clips may come back shorter or longer than a typical YouTube Short.

## License

Clips is available under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Most apps can use Clips for free. At scale, you need a commercial license. The link has the full terms. For licensing, email <licensing@desertant.com>.
