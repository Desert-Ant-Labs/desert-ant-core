<!-- model:start -->
# Gist

Generate topics and tags for posts and articles.

Multilingual on-device content topic tagging across a 36-topic taxonomy.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Languages** | 101 |
| **Weights** | [v2.2.0](https://huggingface.co/desert-ant-labs/gist) |
| **Demo** | https://desertant.com/models/gist/ |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.5.0")
```

Then add the `Gist` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:gist:3.5.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/gist @litertjs/core   # browser
npm i @desert-ant-labs/gist                  # Node, prebuilt native core
```
<!-- model:end -->

## Usage

### Swift

```swift
import Gist

let gist = Gist()
let topics = try await gist.classify("How to start a podcast with just your iPhone")
// [Topic(slug: "technology", name: "Technology & Software", score: 0.93), ...]
```

`classify` accepts `topK`, which defaults to 3, and `threshold`, which defaults to the model's tuned threshold. `scores` gives you the score of every topic instead. To find the main topics of a channel, pass the topics of each post to `channelTopics`:

```swift
let all = try await gist.scores(of: text)        // [String: Double], 36 entries

let posts = titles.map { PostTopics(topics: ..., timestampMillis: ...) }
let channel = channelTopics(posts, options: RollupOptions(topN: 5))
// [ChannelTopic(slug: "technology", share: 0.41, postCount: 12), ...]
```

`channelTopics` is a pure function and runs no model. Recency decay stays off until you pass both `halfLifeDays` and `nowMillis`.

### Kotlin

```kotlin
import ai.desertant.gist.Gist

Gist(context).use { gist ->
    val topics = gist.classify("How to start a podcast with just your iPhone")
    // List<Topic>: slug, name, score
    val all = gist.scores(text)                  // Map<String, Double>
}
```

### JavaScript

```ts
import { Gist } from "@desert-ant-labs/gist";           // browser
// import { Gist } from "@desert-ant-labs/gist/native"; // server-side Node

const gist = await Gist.load();
const topics = await gist.classify("How to start a podcast with just your iPhone");
// [{ slug: "technology", name: "Technology & Software", score: 0.93 }, ...]
gist.dispose();
```

The JavaScript package also exports `channelTopics`, with the same behavior as the Swift SDK:

```ts
import { Gist, channelTopics } from "@desert-ant-labs/gist";

channelTopics(posts, { topN: 5 });
// [{ slug: "technology", share: 0.41, postCount: 12 }, ...]
```

### Choosing a variant

For English and Latin-script text, the English-only build is 15MB, against 74MB for the multilingual build. Only the Swift SDK can select the English build:

```swift
let gist = Gist(variant: .english)
```

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `gist_embedding.i8` + `.json` | int8 static embedding | 64MB | 101-language static embedding, the semantic feature extractor |
| `gist.mlmodelc` | Core ML | 6MB | The classifier head on Apple platforms: fused features → 36 topic probabilities |
| `gist.tflite` | LiteRT | 13MB | The same head, float32, on Android, Linux, Windows, Node, and the web |
| `gist_tokenizer.bin` | Unigram | 4MB | The multilingual tokenizer |
| `gist_config.json` | JSON | tiny | Slugs, feature dims, threshold |
| `taxonomy.json` | JSON | 8KB | The 36 topics (slug, name, description, IAB and Apple category) |

## Inputs and outputs

Pass a plain text string: a title, or a title and a description. Gist works best on short text like posts, titles and descriptions.

Gist gives each of the 36 topics a probability (`features [1, 8448]` → `topic_probs [1, 36]`). Keep the top-k topics above the threshold in `gist_config.json`. Gist is tuned to tag each item with 2-3 topics, which you can then combine across a channel with `channelTopics`.

## Topics and standard taxonomy

The 36 topics map to two industry-standard taxonomies, so you can roll up Gist output or join it into existing systems. One is IAB Content Taxonomy 2.2, with each node's stable integer ID. The other is Apple Podcasts categories. The full, machine-readable crosswalk ships in the Hugging Face repo as [`taxonomy_crosswalk.json`](https://huggingface.co/desert-ant-labs/gist/blob/v2.2.0/taxonomy_crosswalk.json). For example, `law` maps to IAB `383` *News & Politics › Law*, `crafts-hobbies` to IAB `248` *Arts and Crafts*, and `finance` to IAB `391` *Personal Finance*.

Five topics have no dedicated IAB 2.2 node, and the crosswalk flags them as Gist extensions. `society-culture`, `creator-economy` and `outdoors-nature` map to a nearest parent. `history` and `self-improvement` have no IAB node. `film-tv` rolls up IAB *Movies* and *Television*.

## Languages

Gist tags topics in 101 languages. A 15-language spot check across Latin, Cyrillic, Arabic, CJK, Devanagari, Hebrew, Thai and Greek scripts gives 88% top-3. CJK, Arabic and Cyrillic scripts match or beat the Latin ones.

## Model variants

The Hugging Face repo holds two builds of the same 36-topic model:

| Variant | Location | Size | Coverage |
|---|---|---:|---|
| Multilingual (default) | repo root | 74MB | 101 languages |
| English-only | [`en/`](https://huggingface.co/desert-ant-labs/gist/tree/v2.2.0/en) | 15MB | English and Latin script only |

The English build is the same model with a smaller embedding and tokenizer. On English input, the English build gives the same topics as the multilingual build. The English build doesn't cover non-Latin scripts (CJK, Arabic, Cyrillic, …). Use the English build only when the input is reliably English or Latin script.

The JavaScript and Kotlin SDKs load only the multilingual build.

## Evaluation

We measured recall on a held-out set of 572 real posts, labeled by people across the 36 topics. The LLM and the zero-shot classifiers ran zero-shot. Each embedding classifier got a light logistic head. Recall@3 matters most, because apps use the top few topics of each post.

| Model | Type | Size | recall@1 | recall@3 |
|---|---|---:|---:|---:|
| Qwen2.5-7B (cloud) | LLM zero-shot | server | **79%** | n/a |
| multilingual-e5-small + head | transformer embed | 110MB | 74% | 92% |
| bge-small-en + head | transformer embed | 130MB | 71% | 92% |
| **Gist** | **on-device** | **74MB** | **71%** | **91%** |
| all-MiniLM-L6-v2 + head | transformer embed | 90MB | 68% | 90% |
| mDeBERTa-v3-mnli-xnli | zero-shot NLI | 560MB | 50% | 73% |
| GLiClass-base | zero-shot | 400MB | 44% | 65% |

Gist scores 91% recall@3, one point behind the best small models at 92%. Gist is 74MB, against 110-130MB for those two models, and runs in one on-device pass. Gist beats every zero-shot classifier on recall@3 by 18 points or more. Those classifiers never learned the taxonomy or the distribution of posts. Qwen2.5-7B, a cloud LLM, is the only model with a clear lead on recall@1: 79% against 71%.

## License

Gist is available under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Most apps can use Gist for free. At scale, you need a commercial license. The link has the full terms. For licensing, email <licensing@desertant.com>.
