---
license: other
license_name: desert-ant-labs-source-available-1.0
license_link: https://license.desertant.com/1.0
language:
- en
- multilingual
tags:
- text
- topic-classification
- content-classification
- multi-label
- on-device
- core-ml
- tflite
- litert
- multilingual
- model2vec
pipeline_tag: text-classification
library_name: litert
---

# gist: on-device content topic tagging

Takes a piece of text — a title, a post, or a longer description — and returns the topics it is
about, from a fixed **36-topic taxonomy**, across **101 languages**. A compact two-stream classifier
(static embedding + hashed n-grams), with **no transformer at inference**. The deployable model is
**~74 MB** (int8 vocab-pruned multilingual embedding + a small fp16 head) and runs fully on device
with zero per-call cost. Multi-label by design: most items carry two or three topics, and per-item
scores can be aggregated across a collection (for example into channel- or feed-level topics).

> `"How to film a two-person podcast with two iPhones"` → **technology**, **creator-economy** ·
> `"Cómo invertir en fondos indexados"` → **finance** ·
> `"Tips for adopting a rescue dog"` → **pets-animals** ·
> `"投资指数基金入门"` → **finance**

## Try it

- **Live demo:** [desert-ant-labs/gist-demo](https://huggingface.co/spaces/desert-ant-labs/gist-demo) — paste a post in any language and see its topics.
- **SDKs (Swift / Android / JavaScript):** [github.com/Desert-Ant-Labs/gist](https://github.com/Desert-Ant-Labs/gist).

## Use

Drop-in SDKs run the model on device; each pins this repo's revision.

```js
import { Gist } from "@desert-ant-labs/gist";           // browser (wasm + LiteRT.js)
// import { Gist } from "@desert-ant-labs/gist/native"; // Node (native)
const gist = await Gist.load();
await gist.classify("How to start a podcast with just your iPhone");
// [{ slug: "technology", name: "Technology & Software", score: 0.91 },
//  { slug: "creator-economy", name: "Creator Economy & Marketing", score: 0.44 }]
```

```swift
import Gist
let gist = Gist()
let topics = try await gist.classify("How to start a podcast with just your iPhone")
```

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `gist_embedding.i8` + `.json` | int8 static embedding | ~64 MB | 101-language potion embedding (261,349 tokens × 256 dims), the semantic feature extractor |
| `gist.mlmodelc` | Core ML | ~6 MB | The classifier head: fused features → 36 topic probabilities |
| `gist.tflite` | LiteRT | ~13 MB | The same head, float32. Larger than the Core ML export because a float16 graph is not runnable: standard LiteRT/TFLite kernels cannot prepare one whose tensors are all float16, which broke the browser, Android and Linux runtimes until v2.2.0 |
| `gist_tokenizer.bin` | Unigram | ~4 MB | The multilingual tokenizer |
| `gist_config.json` | JSON | tiny | Slugs, feature dims, threshold |
| `taxonomy.json` | JSON | ~8 KB | The 36 topics (slug, name, description, IAB + Apple category) |

## Architecture

A compact two-stream classifier — no large encoder:

- **Semantic stream**: a frozen multilingual static embedding (Model2Vec
  [`potion-multilingual-128M`](https://huggingface.co/minishlab/potion-multilingual-128M), distilled
  from BAAI `bge-m3`), pruned per-script and int8-quantized. Tokenize (Unigram), gather the token
  rows, mean-pool, L2-normalize. Cross-lingual by construction across **101 languages**.
- **Lexical stream**: word and character n-grams hashed into a fixed vector, capturing proper nouns
  and exact tokens the semantic embedding smears (names, brands, gear).
- **Head**: a small MLP fusing the two streams (`[1, 8448]`) into a sigmoid over the **36-topic
  taxonomy**, trained with class balancing so it does not default to over-represented topics.

Distilled: open instruct LLMs (Apache/MIT) label the training text; a small student learns to
reproduce it. Multi-label targets teach the co-occurrences (a tutorial is `technology` *and*
`creator-economy`). Everything except the head is pure host-side code, so the same pipeline runs
identically on Apple (Core ML), Android/Linux (LiteRT), and the web (WebAssembly + LiteRT.js).

## Inputs and outputs

- **Input:** a plain text string (title, or title + description). Best on short text like posts,
  titles, and descriptions.
- **Output:** a probability over the 36 topics (`features [1, 8448]` → `topic_probs [1, 36]`); take
  the top-k above the threshold in `gist_config.json`. Optimized for **multi-label** use — an item's
  2–3 topics, optionally aggregated across a collection.

## Topics and standard taxonomy

The 36 topics map to two industry-standard taxonomies so gist output can be rolled up or joined
into existing systems: **IAB Content Taxonomy 2.2** (with each node's stable integer ID) and
**Apple Podcasts categories**. The full, machine-readable crosswalk ships in this repo as
[`taxonomy_crosswalk.json`](./taxonomy_crosswalk.json) (e.g. `law` → IAB `383` *News & Politics ›
Law*, `crafts-hobbies` → IAB `248` *Arts and Crafts*, `finance` → IAB `391` *Personal Finance*).

Five topics have no dedicated IAB 2.2 node and are flagged as gist extensions
(`society-culture`, `creator-economy`, `outdoors-nature` map to a nearest parent; `history` and
`self-improvement` have no IAB node); `film-tv` is a roll-up of IAB *Movies* + *Television*.

## Languages

Cross-lingual by construction: the multilingual static embedding shares one representation space
across **101 languages**, so topic tagging transfers across all of them. A diverse 15-language spot
check (across Latin, Cyrillic, Arabic, CJK, Devanagari, Hebrew, Thai, and Greek scripts) gives
**88% top-3**, with CJK, Arabic, and Cyrillic scripts matching or beating the Latin ones — topic
classification is largely language-agnostic in the shared embedding.

## Model variants

Two builds of the same 36-topic model live in this repo:

| Variant | Location | Size | Coverage |
|---|---|---:|---|
| **Multilingual** (default) | repo root | ~74 MB | 101 languages |
| **English-only** | [`en/`](./en) | **~15 MB** | English / Latin script only |

The English build is a vocabulary prune of the same model — a smaller int8 embedding (32,251 tokens) and tokenizer, with the **same classifier head**, so it is **topic-identical to the multilingual model on English input** (no retraining). It does not cover non-Latin scripts (CJK, Arabic, Cyrillic, …); use it only when the input is reliably English/Latin. The Swift SDK selects it with `Gist(variant: .english)`. The JS and Kotlin SDKs currently load the multilingual build only: variant selection has to cross the shared native ABI, which has no slot for it yet.

## Evaluation

Recall on a held-out set of **572 human-labeled real posts (36 topics)**, zero-shot for the
LLMs and zero-shot classifiers. Embedding classifiers get a light logistic head trained on the same
corpus; **recall@3** is the product metric (downstream aggregation consumes the top few topics).

| Model | Type | Size | recall@1 | recall@3 |
|---|---|---:|---:|---:|
| Qwen2.5-7B (cloud) | LLM zero-shot | server | **79%** | — |
| multilingual-e5-small + head | transformer embed | 110 MB | 74% | 92% |
| bge-small-en + head | transformer embed | 130 MB | 71% | 92% |
| **gist** | **static embed + n-grams + MLP** | **~74 MB** | **71%** | **91%** |
| all-MiniLM-L6-v2 + head | transformer embed | 90 MB | 68% | 90% |
| potion + head | static embed | 30 MB | 65% | 89% |
| mDeBERTa-v3-mnli-xnli | zero-shot NLI | 560 MB | 50% | 73% |
| GLiClass-base | zero-shot | 400 MB | 44% | 65% |

gist is **tied on recall@3** with the best small models, at a fraction of the size and one on-device
pass — and it beats every zero-shot classifier decisively (they never learned the taxonomy or the
distribution). Only a 7B cloud LLM clearly leads on recall@1. An MTEB cross-check confirms the
transformer edge is genuine static-embedding tradeoff, not a quirk of this gold.

## Built on

- [`minishlab/potion-multilingual-128M`](https://huggingface.co/minishlab/potion-multilingual-128M) (MIT): semantic embedding stream (per-script pruned, int8) + tokenizer lineage.
- [`BAAI/bge-m3`](https://huggingface.co/BAAI/bge-m3) (MIT): teacher the static embedding was distilled from.
- [Model2Vec](https://github.com/MinishLab/model2vec) (MIT): static-embedding distillation method.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for
most apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

## Citation

```bibtex
@software{gist_2026,
  title  = {gist: on-device content topic tagging},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/gist},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
