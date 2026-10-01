<!-- model:start -->
# Tongue

Detect language based on 3 words.

On-device language identification for short text across 84 languages.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Languages** | 84 |
| **Weights** | Bundled with the SDK ([v1.0.0](https://huggingface.co/desert-ant-labs/tongue)) |
| **Demo** | https://desertant.com/models/tongue/ |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.6.0")
```

Then add the `Tongue` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:tongue:3.6.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/tongue
```
<!-- model:end -->

## Usage

Tongue needs no download. The 2MB model ships inside the package. Tongue needs no inference runtime, so `detect` is synchronous and you call it without `await`.

### Swift

```swift
import Tongue

let tongue = try Tongue()                      // loads the bundled 2MB model
let detection = tongue.detect("kann ich das haben")

detection.language          // "de"
detection.reliability       // .confident
detection.candidates        // [Prediction(language: "de", probability: 0.999…), …]
detection.isTooCloseToCall  // false
```

### Kotlin

Tongue has no native code, so you can use Tongue on Android or on any JVM 17+.

```kotlin
import ai.desertant.tongue.Tongue

// Android: pass the Context. On a bare JVM pass null: Tongue.bundled(null).
val tongue = Tongue.bundled(context)
val detection = tongue.detect("kann ich das haben")
detection.language                               // "de"
detection.isTooCloseToCall                       // false
```

### JavaScript

The JavaScript SDK uses the same import in the browser and in Node. Tongue is plain JavaScript, so you install only `@desert-ant-labs/tongue`.

```ts
import { Tongue } from "@desert-ant-labs/tongue";

const tongue = await Tongue.load();                    // Node: reads the bundled model
const detection = tongue.detect("kann ich das haben");
detection.language;                                    // "de"
detection.isTooCloseToCall;                            // false
```

A bundler doesn't serve files out of `node_modules`, so in a browser you serve Tongue's two model files yourself. The package exports `tongue_int8.bin` and `tongue_meta.json` as subpaths, so a copy script can find them with `require.resolve`, under pnpm and Yarn PnP too. Pass the folder you serve them from as `from`:

```ts
const tongue = await Tongue.load({ from: "/models/tongue" });
```

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `tongue_int8.bin` | Raw int8 + fp32 | 2.01MiB | The model the SDKs load. |
| `tongue.onnx` | ONNX (fp32, opset 17) | 8.4MB | Portable graph for onnxruntime and onnxruntime-web. |
| `tongue_meta.json` | JSON | tiny | Runtime tables: label order, hashing constants, script routing. |
| `labels.json` | JSON | tiny | The 59 model labels plus the script-decided languages, with English and native names. |

## Inputs and outputs

Pass a short UTF-8 string. Tongue reads only the first 512 characters. You get ranked ISO 639-1/639-3 codes with probabilities, plus a reliability signal: `confident`, `likely` or `tentative`. For a language Tongue decides by script, you get a single confident answer.

The ONNX graph holds only the classification head. The graph reads `values` (int64 hashed bucket ids) and `offsets` (int64 per-sample starts), and produces `logits`. Your host code runs normalization, hashing and script routing before the graph. `tongue_meta.json` documents those steps.

## Coverage

Tongue covers 84 languages across 31 scripts, among them Latin, Cyrillic, Arabic, Greek and the CJK and Indic families. We trained the lexical model on 59 of the languages. Tongue identifies the other 25 by script alone. Tongue detects one of the 84, Mongolian, only in the traditional Mongolian script. See failure mode 3.

## Failure modes

1. One or two words are often genuinely ambiguous, and no model size fixes that. A single common word often belongs to several languages at once. `"sale"` is English, French and Italian, and `"la casa"` is equally Italian and Spanish. Tongue reports a tie or a tentative answer in these cases. Tongue doesn't catch every case. A phrase that mixes languages, like `"un garage sale"`, can still get a single answer that looks confident. Treat low-reliability output as unknown, and ask for more text where your product allows it.
2. Tongue can't reliably tell Malay and Indonesian apart. The two languages share so much vocabulary and spelling that short samples carry nothing to separate them. Every detector we measured struggles with the pair. If you need the distinction, treat `ms` and `id` as one bucket, or decide from the user's locale.
3. Tongue detects Mongolian only in the traditional Mongolian script. Cyrillic is the dominant modern script for Mongolian. Tongue doesn't tell Cyrillic Mongolian apart from the other Cyrillic languages, and usually returns Russian for it. Don't rely on Tongue for Cyrillic Mongolian.
4. Brand names, numbers and code have no language. `"Samsung Galaxy"`, `"v1.2.3"` and `"2024 annual report"` have no correct answer. Tongue still returns its best guess for anything with letters in it. Filter out input that isn't prose before detection.
5. Single-word scores mostly measure vocabulary recognition, and say less about generalization. The frequent words of a language appear in every detector's training data, so single-word accuracy partly measures memorized vocabulary. Read the word-pair and sentence numbers as the generalization signal.

## Measured quality

We measured every number below on the shipped int8 weights, on three public benchmarks. We ran the other detectors on the same rows and languages. For every score, higher is better.

### FLORES-200

We truncated FLORES-200 sentences to their first 2, 3 and 5 words. The table shows accuracy over the 20 languages the three detectors share.

| Detector | Size | 2 words | 3 words | 5 words |
|---|---|---|---|---|
| **tongue** | **2MB** | **0.869** | **0.933** | **0.974** |
| lingua | 293MB | 0.800 | 0.887 | 0.956 |
| eld | 1MB | 0.780 | 0.856 | 0.912 |

### The lingua test set

lingua publishes this benchmark. The set holds 1,000 single words, word pairs and sentences per language, drawn from the same collection lingua trains on. The table shows accuracy over the languages Tongue and lingua share.

| Detector | Size | Single words | Word pairs | Sentences |
|---|---|---|---|---|
| **tongue** | **2MB** | **0.746** | **0.909** | **0.988** |
| lingua | 293MB | 0.752 | 0.915 | 0.985 |

### The eld benchmark

eld is an independent benchmark. The table shows accuracy over the languages Tongue supports: 53,035 single-word rows, 53,613 word pairs, 53,141 sentences and 9,066 tweets. Apple is the built-in system detector on Apple platforms. HeLI-OTS is a 51MB JVM model. lingua 2.2.0 installs as a single 293MB compiled extension with its language models embedded.

| Detector | Size | Tweets | Single words | Word pairs | Sentences |
|---|---|---|---|---|---|
| **tongue** | **2MB** | **0.992** | **0.759** | **0.887** | **0.971** |
| lingua | 293MB | 0.984 | 0.756 | 0.894 | 0.950 |
| HeLI-OTS | 51MB | 0.986 | 0.683 | 0.843 | 0.967 |
| Apple | system | 0.997 | 0.641 | 0.719 | 0.748 |

## Latency

We timed single detections in JavaScript on an Apple silicon laptop. One word takes 0.013ms. A short sentence takes 0.028ms. A 193-character input takes 0.10ms, with a p99 of 0.24ms. Phones will take longer. The design target is under 1ms.

## License

Tongue is available under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Most apps can use Tongue for free. At scale, you need a commercial license. The link has the full terms. For licensing, email <licensing@desertant.com>.
