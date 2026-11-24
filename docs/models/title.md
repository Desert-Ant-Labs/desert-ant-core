<!-- model:start -->
# Title

Suggest a title and description for any text.

On-device titles and descriptions: a short factual title and a one- to two-sentence description for any passage of text.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android |
| **Weights** | [v0.2.0](https://huggingface.co/desert-ant-labs/title/tree/v0.2.0) |
<!-- model:end -->

Get a title and a one or two sentence description for any passage of text, on device.

Title is fine-tuned on transcript clips, but it works on any prose. The register is deliberately plain, with no emoji, no hashtags and no clickbait, and a description identifies *this* passage rather than its topic.

<!-- model-install:start -->
## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "6.0.0",
        traits: ["MLX"])
```

Then add the `Title` product to your target. The `MLX` trait is required: without it the module compiles as a stub.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation(platform("ai.desertant:bom:6.0.0"))
implementation("ai.desertant:title")
```
<!-- model-install:end -->

## Usage

Title runs on the GPU through MLX on Apple platforms and on the CPU through LiteRT-LM on Android. Create one `Titles` and reuse it to keep the model loaded.

### Kotlin

The first call downloads the model to your app's cache. Call `download()` to fetch and load it ahead of time. To use files you supply, pass a `directory` that contains `litert/title.litertlm`.

```kotlin
import ai.desertant.title.Titles

Titles(context).use { titles ->
    val card = titles.describe(text)
    println(card.title)
    println(card.description)
}
```

`describe()` runs off the main thread. Each call starts with a fresh generation session. Android limits each reply to 96 tokens and shortens long passages to fit the 1,280-token context.

### Swift

Download the Apple model files from Hugging Face and pass their folder to the initializer.

```swift
import Title

let titles = try await Titles(directory: modelFolder)
let card = try await titles.describe(text)

card.title          // "Filming a two-person podcast on iPhone"
card.description    // one or two sentences
card.isEmpty        // true when the model returned neither
```

On unusual input, Title can keep generating without end. `maxTokens` caps each run, at 96 tokens by default:

```swift
let titles = try await Titles(directory: modelFolder, maxTokens: 96)
```

On iOS, call `suspend()` before your app enters the background and `resume()` when it returns. iOS revokes GPU access in the background. `suspend()` cancels the running generation, and the call retries after `resume()`.

### With Clips

To give each clip a title and a description, pass the clips to Title. `cards(for:)` returns the cards in the same order as the clips.

```swift
let cards = try await titles.cards(for: moments)   // index-aligned with moments
let card = try await titles.card(for: moments[0])
```

`cards(for:)` writes one card at a time. One generation already keeps the GPU busy, so parallel generations aren't faster. On a phone, parallel generations also add heat, and the phone throttles partway through a long video.

### Other kinds of text

We fine-tuned Title on transcript clips. Title also writes accurate cards for news paragraphs, product descriptions and emails. Title can still get details wrong on general prose.

## Files

The Android SDK uses `litert/title.litertlm` (364 MB), which contains the int8 model, tokenizer, and stop-token metadata. LiteRT-LM writes its CPU weights cache beside the bundle. The bundle and cache used about 720 MB together on ARM64.

On Apple platforms, pass the whole MLX folder to `Titles(directory:)`.

| File | Contents |
|---|---|
| `model.safetensors` | 6-bit quantized weights |
| `model.safetensors.index.json` | Shard index. Keep this file: the loader needs it, even with a single shard. |
| `config.json` | Architecture and quantization config |
| `generation_config.json` | Decode defaults |
| `tokenizer.json`, `tokenizer_config.json` | Byte-level BPE with merges |
| `chat_template.jinja` | The chat template we trained the fine-tune against |

Keep the chat template as shipped. A different template changes the task the model performs.

## The prompt

The SDK asks Title for a factual title and description in the language of the passage and parses the reply for you. The expected reply has two labeled lines:

```
TITLE: <3-8 words, no final punctuation>
DESC: <1-2 sentences>
```

The model sometimes drifts off this format, so parse the reply tolerantly. When the reply has no labels, the SDK takes the first line as the title. When the SDK finds neither a title nor a description, `card.isEmpty` is true.

## Performance

On a Nothing Phone (3), the Android export took a median 1.20 s per card on CPU for 220 transcript clips, excluding model load. The benchmark used the training prompt for video clips.

## Limitations

- Title sometimes opens a description with a stock phrase that its instruction forbids. Read each card before it reaches a user.
- Title can get details wrong on general prose. It's most accurate on transcript clips, news paragraphs, product descriptions and emails.
- On unusual input, Title can keep generating until it hits the reply token cap. Swift apps can set that cap with `maxTokens`.
- In the same Android benchmark, 99.4% of the 180 Latin-script clips and 17.5% of the 40 non-Latin-script clips produced both fields and stopped within the token cap. Non-Latin replies often reached the cap.

## Built on

- [`ibm-granite/granite-4.0-350m`](https://huggingface.co/ibm-granite/granite-4.0-350m): the base model we fine-tuned Title from.

<!-- model-footer:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

Third-party notices for the weights: [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/title/blob/main/THIRD_PARTY_NOTICES.md).

## Citation

```bibtex
@software{title_2026,
  title  = {Title: On-device titles and descriptions: a short factual title and a one- to two-sentence description for any passage of text},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/title},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
<!-- model-footer:end -->
