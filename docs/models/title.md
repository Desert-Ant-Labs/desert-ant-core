<!-- model:start -->
# Title

Names what you just wrote.

On-device titles and descriptions: a short factual title and a one- to two-sentence description for any passage of text.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS |
| **Weights** | [v0.1.0](https://huggingface.co/desert-ant-labs/title) |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.1.0",
        traits: ["MLX"])
```

Then add the `Title` product to your target. The `MLX` trait is required: without it the module compiles as a stub.
<!-- model:end -->

## Usage

Apple only, and the one model here that runs on MLX rather than Core ML: short
autoregressive decode measured 5.7-8.3x faster on the GPU than on the Neural
Engine. That is why it is behind the `MLX` package trait, and why a build that
forgets the trait fails at compile time instead of mis-building.

Loading is expensive and generation is cheap, so build one `Titles` and reuse
it. It is an `actor` because MLX state is not safe to drive from several tasks
at once.

### Swift

Nothing is downloaded here. Point the initializer at a folder you populated with
the model files, unlike the other models in this repo:

```swift
import Title

let titles = try await Titles(directory: modelFolder)
let card = try await titles.describe(text)

card.title          // "Filming a two-person podcast on iPhone"
card.description    // one or two sentences
card.isEmpty        // true when the model returned neither
```

`maxTokens` caps a degenerate run, which is a real failure mode for a small
instruct model given unusual input:

```swift
let titles = try await Titles(directory: modelFolder, maxTokens: 96)
```

### With Clips

`Card` is owned by this module and is not a field on `Clip`: selection and card
writing are separate stages on separate silicon. Pair them when you want both.

```swift
let cards = try await titles.cards(for: moments)   // index-aligned with moments
let card = try await titles.card(for: moments[0])
```

`cards(for:)` is sequential on purpose. Decode is already GPU-bound, so
overlapping generations contend for the same device rather than adding
throughput, and on a phone it adds thermal pressure that shows up as throttling
partway through a long video.

### Not clip-specific

The model was fine-tuned on transcript clips, but the task it learned is
general: news paragraphs, product descriptions and emails all produce accurate,
correctly-registered cards. Treat it as capable on general prose, not
infallible on it.

## Files

An MLX model directory. Load the folder, not a single file.

| File | Contents |
|---|---|
| `model.safetensors` | 6-bit quantized weights |
| `model.safetensors.index.json` | shard index; present even for one shard, because the loader reads it |
| `config.json` | architecture and quantization config |
| `generation_config.json` | decode defaults |
| `tokenizer.json`, `tokenizer_config.json` | byte-level BPE with merges |
| `chat_template.jinja` | the chat template the fine-tune was trained against |

The chat template is not incidental. A different template is a different task to this model.

## The prompt

The model was fine-tuned against one specific instruction, and a paraphrase is a different
task to it. It lives in `Titles.prompt` in the SDK; use that wording. The reply is two labelled
lines:

```
TITLE: <3-8 words, no final punctuation>
DESC: <1-2 sentences>
```

Parse tolerantly. A card model that drifts off format should degrade to a usable title rather
than throw.

## Apple only

MLX runs on Apple silicon and nowhere else, so there is no Android, Linux or Windows artifact
here and no manifest promising one. A Core ML export exists in the training repository and is
kept as evidence rather than as a candidate: on short autoregressive decode the Neural Engine
is bandwidth-bound, and the Core ML arm lost on first token, throughput, load time and resident
memory.

## Status

Internal testing, and less settled than that phrase usually implies. This card carries no
quality figures: no independent review has been completed, and a known open issue is that the
model sometimes opens a description with a stock phrase its own instruction forbids. Treat the
output as needing a read before it reaches a user.

## Built on

- [`ibm-granite/granite-4.0-350m`](https://huggingface.co/ibm-granite/granite-4.0-350m):
  the base model this is fine-tuned from.

See [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/title/blob/v0.1.0/THIRD_PARTY_NOTICES.md).

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for most
apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

---

© 2026 Desert Ant Labs · <https://desertant.com>
