---
license: other
license_name: desert-ant-labs-source-available-1.0
license_link: https://license.desertant.com/1.0
language:
- multilingual
tags:
- text
- emoji
- text-classification
- on-device
- core-ml
- litert
- tflite
- multilingual
pipeline_tag: text-classification
---

# Emo: on-device emoji suggestions from text

Takes a short text string and returns the best-matching emoji. Tuned for to-dos,
calendar entries, notes, and message drafts across **23 languages** (including
CJK, Arabic, Thai, Hindi, and more). The whole thing, model **and** tokenizer,
is small (**~5 MB** on Apple via Core ML, **~11 MB** via LiteRT elsewhere) and runs in well under 2 ms on device.

> `"Dentist appointment"` → 🦷  ·  `"réserver un vol pour Tokyo"` → ✈️  ·  `"犬の散歩"` → 🐕  ·  `"จองโรงแรม"` → 🏨

## Try it

All platforms ship from one repo: **[Desert-Ant-Labs/emo](https://github.com/Desert-Ant-Labs/emo)** (Swift, Kotlin, and JavaScript in a single codebase).

- **Live demo:** [desert-ant-labs/emo-demo](https://huggingface.co/spaces/desert-ant-labs/emo-demo): type a phrase, get emojis, fully in your browser.
- **iOS / macOS / tvOS / visionOS:** the Swift SDK (Swift Package Manager), with a built-in demo app. It bundles the compiled Core ML model below.
- **Android / Kotlin:** Maven Central `ai.desertant:emo` with LiteRT (`.tflite`). The small model is bundled by default; exclude `ai.desertant:emo-tflite-resources` to force on-demand download or explicit-directory loading.
- **Node / browser (JavaScript / TypeScript):** `npm i @desert-ant-labs/emo @litertjs/core` for browser builds, or just `npm i @desert-ant-labs/emo` for server-side Node. The npm package downloads the model from this repo on first use and caches it; browser inference uses [LiteRT.js](https://www.npmjs.com/package/@litertjs/core), and Node uses prebuilt native libraries (Core ML on macOS, LiteRT on Linux). Pass `directory` (Node) or `modelBaseUrl` (browser) to self-host / run offline.

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

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for
most apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

## Citation

```bibtex
@software{emo_2026,
  title  = {Emo: on-device emoji suggestions from text},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/emo},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
