<!-- model:start -->
# Toxic

Catch hate speech before it's posted.

On-device hate-speech triage in 35 languages.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Languages** | 35 |
| **Weights** | [v0.2.2](https://huggingface.co/desert-ant-labs/toxic/tree/v0.2.2) |
| **Demo** | https://desertant.com/models/toxic/ |
| **Status** | Beta |
<!-- model:end -->

Toxic flags hateful, abusive and threatening text on device, in 35 languages, so you can warn the writer or hold a message for review before it's posted. For hate speech, Toxic also names the type of protected characteristic the message targets, such as religion, gender or age. Toxic runs on iPhone, iPad, Mac, Apple TV, Vision Pro, Android, Linux, Windows, in the browser and in Node, and text stays on device. On an iPhone 16 Pro, Toxic scores a short message in 2.0ms.

<!-- model-install:start -->
## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "5.0.0")
```

Then add the `Toxic` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:toxic:5.0.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/toxic @litertjs/core   # browser
npm i @desert-ant-labs/toxic                  # Node, prebuilt native core
```
<!-- model-install:end -->

## Usage

### Swift

```swift
import Toxic

let toxic = Toxic()
let result = try await toxic.analyze(comment)
if result.isToxic { holdForReview(result.content, result.targets) }
result.score(.hateful)     // 0...1
result.flagged             // the heads at or above their thresholds
```

Pass the text exactly as written. The SDK doesn't lower-case, trim or remove anything, including punctuation, emoji and markup. To stop an analysis, cancel the task that called `analyze`, and `analyze` throws `CancellationError`. On Apple platforms, the Toxic model runs entirely on the Neural Engine. To use other compute units, pass `computeUnits:` to `Toxic(directory:computeUnits:)`.

### Kotlin

```kotlin
import ai.desertant.toxic.Toxic
import ai.desertant.toxic.Options

Toxic(context).use { toxic ->
    val result = toxic.analyze(comment)
    if (result.isToxic) holdForReview(result.content, result.targets)
}
```

### JavaScript

```ts
import { Toxic } from "@desert-ant-labs/toxic";         // browser
// import { Toxic } from "@desert-ant-labs/toxic/native"; // server-side Node

const toxic = await Toxic.load();
const { isToxic, scores, content, targets } = await toxic.analyze(comment);
toxic.dispose();
```

### What comes back

Every SDK returns the same fields.

| Field | |
| --- | --- |
| `scores` | Every head's probability in `0...1`: `HATEFUL`, `ABUSIVE`, `THREAT`, and the eight target heads `RACE`, `RELIGION`, `NATIONAL_ETHNIC_ORIGIN`, `SEXUAL_ORIENTATION`, `GENDER`, `DISABILITY`, `AGE`, `OTHER`. |
| `thresholds` | The threshold each head was judged at. |
| `flagged` | The heads at or above their thresholds, content and target heads alike. |
| `content` | The content heads that fired: what the text does. `HATEFUL` is incitement to hatred or violence against a group, `ABUSIVE` insulting or degrading language, aimed or not, `THREAT` a threat of violence. |
| `targets` | The target heads that fired, highest score first: which group a hateful text is about. Read them when `HATEFUL` fired. |
| `isToxic` | Whether a content head fired. |

### Options

| Option | Default | |
| --- | --- | --- |
| `thresholds` | the model's | A label to the threshold that replaces the model's default for that head. The defaults ship with the model, chosen on validation text (`Toxic.defaultThresholds()` in Swift). Raise a threshold to flag less, lower it to flag more. |

### Long texts

Toxic reads 128 tokens at a time, about 80 words. For a longer text, Toxic reads overlapping windows of that length, and the text gets the highest score of any of its windows.

### Loading the model

The SDK downloads the weights from Hugging Face on first use and caches them. See [model downloads and caching](../../README.md#model-downloads-and-caching).

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `coreml-mixed/toxic.mlmodelc` | Compiled Core ML, the layers 8-bit | 43MB | The graph on Apple platforms, every op on the Neural Engine (used by the Swift SDK) |
| `litert-mixed/toxic.tflite` | LiteRT, the layers 8-bit | 44MB | The graph on Android, Linux, Windows, Node, and the web (downloaded on demand by the Kotlin and JavaScript SDKs) |
| `coreml-mixed/toxic_meta.json`, `litert-mixed/toxic_meta.json` | JSON | 2KB | The graph's input and output names, the heads in output order, the table's and the tokenizer's shapes, the default thresholds |
| `toxic_table.bin` | The embedding table as the SDK reads it, 4-bit | 50MB | The rows the SDK looks a text's tokens up in and feeds the graph, shared by both runtimes |
| `toxic_tokenizer.bin` | The tokenizer as the SDK reads it | 9.4MB | The pieces, the merges and the added tokens of the encoder's tokenizer, shared by both runtimes |

## Results

We tested Toxic and seven other guard and toxicity models that run on device, on eight public test sets in 43 languages. None of the sets were in Toxic's training data. Each model ran as published by its maker, with its categories matched to Toxic's three scores.

Each cell is the median macro F1 over the sets that label that category. Macro F1 penalizes both missed texts and clean texts flagged in error, and a perfect score is 1.0. Bold marks the best score in each size group.

| Model | Parameters | Hateful | Abusive | Threat |
| --- | ---: | ---: | ---: | ---: |
| *Under 2B parameters* | | | | |
| Toxic | 0.14B | **0.652** | **0.683** | 0.516 |
| Detoxify multilingual | 0.28B | 0.513 | 0.449 | 0.537 |
| Qwen3Guard 0.6B | 0.6B | 0.614 | 0.562 | **0.693** |
| Llama Guard 3 1B | 1.5B | 0.621 | n/a | 0.648 |
| PolicyLM 1.7B | 1.7B | 0.650 | 0.655 | 0.535 |
| *2B parameters and above* | | | | |
| ShieldGemma 2B | 2.6B | 0.721 | 0.502 | 0.655 |
| Shieldstral 3B | 3.4B | **0.732** | **0.729** | **0.772** |
| Qwen3Guard 4B | 4.0B | 0.647 | 0.585 | 0.733 |

Among the models under 2B parameters, Toxic has the highest abuse score, 0.683 against 0.655 for PolicyLM 1.7B. On hate, Toxic scores 0.652 and PolicyLM 0.650, at a twelfth of PolicyLM's size. Shieldstral 3B has the highest score in all three categories and is about 24 times the size of Toxic.

Toxic has the lowest threat score in the table. Most of these sets count any violent language as a threat, and Toxic only flags threats of violence. To flag more threats, lower the `THREAT` threshold (see [Options](#options)).

The eight sets are RTP-LX, TextDetox multilingual toxicity, Aya red-teaming, the OpenAI moderation evaluation set, ToxiGen (annotated), ToxicChat, the ALIA-es human test set and News-RO-Offense. Llama Guard 3 has no category for abuse.

## Performance

Toxic scores a short message in 2.0ms on an iPhone 16 Pro and in 17ms on a Galaxy S26. Each time is the median of 50 calls through SDK 4.3.0, one message of up to 80 words per call, and leaves out the time to load the model.

| Device | Runtime | Per text |
| --- | --- | ---: |
| MacBook Pro M5 Pro | Core ML | 1.6ms |
| iPhone 16 Pro | Core ML | 2.0ms |
| Mac mini M1 | Core ML | 2.7ms |
| MacBook Pro 16 M1 Max | Core ML | 2.9ms |
| Linux, x86-64 | LiteRT, CPU | 8.6ms |
| Galaxy S26, Exynos 2600 | LiteRT, CPU | 17ms |
| Windows, AMD Ryzen AI 300 | LiteRT, CPU | 20ms |
| Windows, Intel Core Ultra 200V | LiteRT, CPU | 47ms |

## Limitations

Toxic is a triage aid. Send flagged messages to a reviewer or a stricter check instead of removing them automatically.

- Toxic flags hateful words whether a message uses them or quotes them, so Toxic can flag a message that only reports hate speech.
- Toxic doesn't always separate hate speech from language that is only offensive.
- Toxic has the lowest threat score in the comparison above.

<!-- model-footer:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

Third-party notices for the weights: [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/toxic/blob/main/THIRD_PARTY_NOTICES.md).

## Citation

```bibtex
@software{toxic_2026,
  title  = {Toxic: On-device hate-speech triage in 35 languages},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/toxic},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
<!-- model-footer:end -->
