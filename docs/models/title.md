<!-- model:start -->
# Title

Suggest a title and description for any text.

On-device titles and descriptions: a short factual title and a one- to two-sentence description for any passage of text.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS |
| **Weights** | [v0.1.0](https://huggingface.co/desert-ant-labs/title) |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.6.0",
        traits: ["MLX"])
```

Then add the `Title` product to your target. The `MLX` trait is required: without it the module compiles as a stub.
<!-- model:end -->

## Usage

Title runs only on Apple platforms, on the GPU through MLX. The other Desert Ant models on Apple platforms run on Core ML. We measured Title writing text 5.7-8.3x faster on the GPU than on the Neural Engine. Because Title needs MLX, you turn Title on with the `MLX` package trait. A build that leaves out the trait fails at compile time, so you can't ship an app without a working model by mistake.

Loading the model is slow and writing a card is fast, so create one `Titles` and reuse it. `Titles` is an `actor`, because MLX isn't safe to drive from several tasks at once. Calls from several tasks run one at a time.

On iOS, call `suspend()` before your app enters the background and `resume()` when it returns. iOS revokes GPU access in the background, and MLX crashes the app if a generation is still running. `suspend()` cancels the running generation, and the call retries after `resume()`.

### Swift

Title doesn't download its weights. Download the model files from Hugging Face, and point the initializer at that folder:

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

Title's files form one MLX model folder. Pass the whole folder to `Titles(directory:)`.

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

The SDK sends Title the exact instruction we fine-tuned the model on, and parses the reply for you. The model replies with two labeled lines:

```
TITLE: <3-8 words, no final punctuation>
DESC: <1-2 sentences>
```

The model sometimes drifts off this format, so parse the reply tolerantly. When the reply has no labels, the SDK takes the first line as the title. When the SDK finds neither a title nor a description, `card.isEmpty` is true.

## Apple only

MLX runs only on Apple silicon, so Title has no Android, Linux, Windows, browser or Node build. We also built Title for Core ML, to compare. The Neural Engine is limited by memory bandwidth when a model writes short text one token at a time. The Core ML build lost to MLX on time to first token, tokens per second, load time and memory use. We don't plan to ship the Core ML build.

## Status

Title is in internal testing. We publish no quality figures for Title yet, because no independent review is complete. Title sometimes opens a description with a stock phrase that its instruction forbids. Read each card before it reaches a user.

## Built on

- [`ibm-granite/granite-4.0-350m`](https://huggingface.co/ibm-granite/granite-4.0-350m): the base model we fine-tuned Title from.

See [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/title/blob/v0.1.0/THIRD_PARTY_NOTICES.md).

## License

Title is available under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Most apps can use Title for free. At scale, you need a commercial license. The link has the full terms. For licensing, email <licensing@desertant.com>.
