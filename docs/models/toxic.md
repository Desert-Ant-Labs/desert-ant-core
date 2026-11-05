<!-- model:start -->
# Toxic

Catch hate speech before it posts.

On-device hate-speech triage for European languages.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Languages** | 35 |
| **Weights** | [v0.2.2](https://huggingface.co/desert-ant-labs/toxic/tree/v0.2.2) |
| **Demo** | https://desertant.com/models/toxic/ |
| **Status** | Beta |
<!-- model:end -->

<!-- model-install:start -->
## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.3.0")
```

Then add the `Toxic` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:toxic:4.3.0")
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

The text goes in as written: no lower-casing, no stripping. Canceling the calling task stops the analysis and throws `CancellationError`. On Apple platforms every op of the graph runs on the Neural Engine; the SDK tokenizes and looks the tokens' rows up itself and feeds the graph embeddings. Pass `computeUnits:` to `Toxic(directory:computeUnits:)` to change the units.

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

Every SDK returns the same analysis:

| Field | |
| --- | --- |
| `scores` | Every head's probability in `0...1`: `HATEFUL`, `ABUSIVE`, `THREAT`, and the eight target heads `RACE`, `RELIGION`, `NATIONAL_ETHNIC_ORIGIN`, `SEXUAL_ORIENTATION`, `GENDER`, `DISABILITY`, `AGE`, `OTHER`. |
| `thresholds` | The threshold each head was judged at. |
| `flagged` | The heads at or above their thresholds, content and target heads alike. |
| `content` | The content heads that fired: what the text does. `HATEFUL` is incitement to hatred or violence against a group, `ABUSIVE` insulting or degrading language, aimed or not, `THREAT` a threat of violence. |
| `targets` | The target heads that fired, highest score first: which group a hateful text is about. Read them when `HATEFUL` fired. |
| `isToxic` | Whether a content head fired. |

Toxic is a triage signal for human review or a stricter check, not a verdict: it reacts to hateful words whether a text uses them or quotes them, and the line between hate and merely offensive text is soft.

### Options

| Option | Default | |
| --- | --- | --- |
| `thresholds` | the model's | A label to the threshold that replaces the model's default for that head. The defaults ship with the model, chosen on validation text (`Toxic.defaultThresholds()` in Swift). Raise a threshold to flag less, lower it to flag more. |

### Long texts

The graph reads 128 tokens at a time, about 80 words. A longer text is read in overlapping windows, and each head keeps its highest score over them, so a long text's score is its worst window's.

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

<!-- model-footer:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

Third-party notices for the weights: [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/toxic/blob/main/THIRD_PARTY_NOTICES.md).

## Citation

```bibtex
@software{toxic_2026,
  title  = {Toxic: On-device hate-speech triage for European languages},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/toxic},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
<!-- model-footer:end -->
