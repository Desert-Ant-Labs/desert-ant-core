---
license: other
license_name: desert-ant-labs-source-available-1.0
license_link: https://license.desertant.com/1.0
language:
- multilingual
tags:
- text
- clip-selection
- text-ranking
- on-device
- core-ml
- litert
- tflite
- multilingual
pipeline_tag: text-ranking
---

# clips

Takes the sentences of a transcript and ranks contiguous spans, so a longer video can be cut
into shorter clips.

Selection is two graphs. A per-sentence **selector** returns a saliency score and start/end
probabilities, which is what proposes candidate spans. A per-span **scorer** then ranks them.
They are separate graphs because they take different inputs: the selector also reads five
discourse scalars the scorer has no use for.

On Apple platforms both graphs live in **one** Core ML package over a shared trunk. LiteRT has
no equivalent packaging, so the other platforms ship two files and store the trunk twice.

## Files

| File | Format | Contents |
|---|---|---|
| `clips.mlmodelc/` | Compiled Core ML, int8 | Multifunction package. Function `select`: `ids`, `mask`, `disc` → `saliency`, `start_p`, `end_p`. Function `score`: `ids`, `mask` → `score` |
| `clips-selector.tflite` | LiteRT, int8 weight-only | The selector, for Android, Linux and Windows |
| `clips-scorer.tflite` | LiteRT, int8 weight-only | The scorer, for Android, Linux and Windows |
| `clip_tokenizer.bin` | Unigram tokenizer | XLM-R SentencePiece pieces and scores, in the compact binary the runtime reads |
| `clips_meta.json` | JSON | Graph widths, discourse-feature order and tokenizer ids a runtime needs |
| `checkpoint/` | safetensors + PyTorch | The training checkpoint the exports were built from |

### Reaching a function in the Core ML package

A file path names the package, not the graph. Loading needs
`MLModelConfiguration.functionName` set to `select` or `score`. Without it Core ML loads the
package's default function and reports nothing, so both halves of the pipeline end up being
the selector.

### Windows

The selector runs at 128 tokens, the scorer at 256, both at a fixed batch of 16 sentences.

A single sentence is truncated to **64** tokens before it reaches the selector. That is the
length the saliency heads were trained at and it is not the same thing as the graph width; a
longer single sentence runs the heads off-distribution.

### `checkpoint/`

The exact checkpoint the exports come from, in the layout the training and export scripts
read, rather than a flat repacked `.pt` that nothing can load. It holds the encoder as
safetensors, the two head files, and `run_manifest.json` describing the run that produced it.

There is no TensorFlow checkpoint. The LiteRT files are converted from PyTorch through
StableHLO, so no TF SavedModel exists at any point.

## Status

Internal testing. This card carries no quality or latency figures: the evaluation behind this
checkpoint has not completed independent review, and an unreviewed number on a public card
gets quoted as if it had been.

> ### ⚠️ The `.tflite` files do not work with the Desert Ant SDK yet. Do not build on them.
>
> Found by review after publication, by loading the flatbuffers rather than reasoning about
> them. The LiteRT exports are real and faithful conversions of the checkpoint, but the SDK's
> LiteRT backend cannot drive them:
>
> - the graphs name their inputs `args_0`, `args_1`, `args_2` and their outputs `output_0…2`;
>   the SDK asks for `ids`, `mask`, `disc` and `saliency`, `start_p`, `end_p`. There is no
>   mapping layer, so the first call fails.
> - the graphs take **int64** ids and mask; the SDK builds int32.
> - the scorer is 256 wide and the SDK's LiteRT backend cannot report a width, so it falls
>   back to 128.
>
> They are left published because they are honest artifacts and someone driving LiteRT
> directly can use them — the shapes and output order are in `clips_meta.json` and are
> verified. They are **not** a working Android/Linux/Windows path today.
>
> Also unresolved: at these widths this export was measured at ~2.1 GB peak RSS against a
> 1.6 GB Android budget, and the training repo's own recommendation for LiteRT is fp16 rather
> than this int8 build.

**The two platforms are not equally evidenced.** The Core ML package has clips that were
generated from it and judged. **No clip has ever been read from the LiteRT files, on any
platform.** Their only gate is a synthetic random-token batch, and that gate's own manifest
records `is_a_quality_result: false`. The two exports also use different int8 schemes, recorded
per platform in `clips_meta.json`.

## Requirements

The Core ML package is **specification version 9**: it requires **iOS 18 / macOS 15 / tvOS 18 /
visionOS 2 / watchOS 11**, read off the compiled artifact. Reaching either graph needs
`MLModelConfiguration.functionName` set to `select` or `score`.

## Limits

Behaviour worth knowing before you build on it, stated without figures for the reason above:

- **It under-emits on short video.** Given a short transcript it returns markedly fewer clips
  than a strong teacher finds worth cutting. If your product needs a guaranteed number of
  clips from a two-minute video, measure before relying on it.
- **It emits some dross**, most on podcast-length input. There is no confidence score to
  filter on yet: `Clip.score` ranks within one video and is not calibrated across videos.
- **The clip limit is a cap, not a quota.** Asking for 10 does not mean receiving 10.
- **Selection is sensitive to small score changes.** Candidate spans around one moment score
  very close together, so a different runtime, compute unit or quantization can return a
  different-but-comparable set rather than the same set. Do not treat exact span equality
  between two builds as a correctness check.
- **Non-Latin scripts are under-tested.** The evaluation corpus is overwhelmingly Latin-script.
- **Duration is a soft prior, not a rule.** Clips may come back shorter or longer than a
  typical Short.

## Built on

- [`FacebookAI/xlm-roberta-base`](https://huggingface.co/FacebookAI/xlm-roberta-base) (MIT):
  the shared encoder trunk and its SentencePiece vocabulary.

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for most
apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

---

© 2026 Desert Ant Labs · <https://desertant.com>
