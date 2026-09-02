<!-- model:start -->
# Emo

Suggest emoji faster than you can type.

Multilingual on-device emoji suggestion.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Languages** | 22 |
| **Weights** | [v0.7.0](https://huggingface.co/desert-ant-labs/emo) |
| **Demo** | https://desertant.com/models/emo/ |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.1.0")
```

Then add the `Emo` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:emo:3.1.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/emo @litertjs/core   # browser
npm i @desert-ant-labs/emo                  # Node, prebuilt native core
```
<!-- model:end -->

## Usage

Create one instance and reuse it. Construction is cheap and non-blocking; the
model loads on first use, or earlier if you call `download`.

### Swift

```swift
import Emo

let emo = Emo()
let suggestions = try await emo.suggestions(for: "Pay my bills")
// [EmoSuggestion(emoji: "💰", confidence: ...), ...]

let toned = try await emo.suggestions(for: "go for a run", limit: 1, skinTone: .medium)
// 🏃🏽
```

### Kotlin

`suggestions` and `download` are suspending functions. A model owns native
resources, so close it when you are done, or let `use { }` do it.

```kotlin
import ai.desertant.emo.Emo
import ai.desertant.emo.EmojiSkinTone

Emo(context).use { emo ->
    val suggestions = emo.suggestions("Pay my bills")               // List<EmoSuggestion>
    val toned = emo.suggestions("go for a run", limit = 1, skinTone = EmojiSkinTone.MEDIUM)
}
```

### JavaScript

The default import is the browser build. For inference in plain Node, import the
`/native` subpath, which ships prebuilt for linux-x64, linux-arm64 and darwin-arm64.

```ts
import { Emo } from "@desert-ant-labs/emo";           // browser
// import { Emo } from "@desert-ant-labs/emo/native"; // server-side Node

const emo = await Emo.load();                                // downloads and caches on first use
const suggestions = await emo.suggestions("Pay my bills");   // [{ emoji, confidence }, ...]
emo.dispose();
```

### Loading the model

The weights are fetched from the Hub on first use and cached. To fetch them
earlier, for example during onboarding, or to ship them yourself, see
[model downloads and caching](../../README.md#model-downloads-and-caching).

```swift
let emo = Emo()
if !emo.isDownloaded() {
    try await emo.download { fraction in print("\(Int(fraction * 100))%") }
}

let offline = Emo(directory: myModelDirectory)   // adopted as-is, nothing downloaded
```

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `emo.tflite` | LiteRT / TFLite (int8) | ~10.2 MB | Fixed-window n-gram + masked semantic inputs, softmax `probabilities` output; runs on Android, Linux, Node, and the web (bundled by default in the Kotlin SDK; downloaded on demand by the JavaScript SDK) |
| `emo.mlmodelc` | Compiled Core ML | ~4.6 MB | Mixed 4-/8-bit-palettized transformer, ready to load on Apple platforms (used by the Swift SDK) |
| `emo_tokenizer.bin` | Pruned unigram tokenizer | ~0.75 MB | 48k SentencePiece pieces + scores; token ids = semantic-table rows |
| `emo_meta.json` | JSON | tiny | emoji labels + n-gram hashing / fixed-window config the runtime needs |
| `emo.pt` | PyTorch checkpoint | ~48 MB | Full-precision weights + semantic table + tokenizer (for retraining / other runtimes) |

Older revisions (tags `v0.6.0` and earlier) carry `Emo.mlmodelc` and `emo.safetensors` for SDK versions that predate the unified cross-platform migration.

## Architecture

A compact two-stream classifier - no large encoder, just a tiny transformer over the semantic tokens:

- **Lexical stream**: script-aware character/word n-grams (Latin, Han·Kana, Hangul
  jamo, Devanagari clusters, SE-Asian, …) hashed into a fixed multi-hash signed
  embedding table. Its size is independent of the number of languages.
- **Semantic stream**: a frozen multilingual static embedding (Model2Vec
  [`potion-multilingual-128M`](https://huggingface.co/minishlab/potion-multilingual-128M),
  distilled from BAAI `bge-m3`), PCA-reduced to 128 dims and **vocab-pruned to the
  48k tokens** that matter for the 22 target languages. Gives cross-lingual
  generalization and handles out-of-vocabulary words. The matching ~0.75 MB unigram
  tokenizer ships alongside (`emo_tokenizer.bin`).
- **Semantic pooling**: a small 2-layer transformer encoder runs over the semantic
  token sequence, then an attention pool - order-aware, so it composes phrases and
  idioms instead of averaging tokens.
- **Head**: a small MLP fusing the two streams into a softmax over a **curated vocabulary of ~800 everyday emojis** (the emojis that actually come up most across the
  training phrases). Trained with n-gram dropout so the head relies on the semantic
  stream, which is what makes it generalize across languages.

## Inputs and outputs

- **Input:** a plain text string. Best on short, intent-oriented text.
- **Output:** a probability distribution over the ~800-emoji vocabulary; take the
  top-1 (or top-k). Optimized for **top-1 relevance**.

## Languages

English, Spanish, Portuguese, French, German, Italian, Dutch, Russian, Polish,
Turkish, Arabic, Chinese (Simplified & Traditional), Japanese, Korean, Hindi,
Indonesian, Thai, Vietnamese, Ukrainian, Swedish, Danish, Czech.

## Limitations

- Tuned for short, intent-oriented text; long-form text produces noisier suggestions.
- Emoji semantics are imprecise; near-ties at the top of the ranking are expected.
- Per-language quality varies; lower-resource languages in the set are somewhat weaker.

## Built on

- [`minishlab/potion-multilingual-128M`](https://huggingface.co/minishlab/potion-multilingual-128M) (MIT): semantic embedding stream (PCA-reduced, vocab-pruned derivative) + tokenizer lineage.
- [`BAAI/bge-m3`](https://huggingface.co/BAAI/bge-m3) (MIT): teacher the static embedding was distilled from.
- [Model2Vec](https://github.com/MinishLab/model2vec) (MIT): static-embedding distillation method.
- Unicode CLDR emoji annotations: multilingual keyword grounding in the training data.

See [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/emo/blob/v0.7.0/THIRD_PARTY_NOTICES.md).

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for
most apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.
