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
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.1.0")
```

Then add the `Tongue` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:tongue:3.1.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/tongue
```
<!-- model:end -->

## Usage

Nothing to download and nothing async: the 2 MB model ships inside the package,
and a detection is pure arithmetic.

### Swift

```swift
import Tongue

let tongue = try Tongue()                      // loads the bundled 2 MB model
let detection = tongue.detect("kann ich das haben")

detection.language          // "de"
detection.reliability       // .confident
detection.candidates        // [Prediction(language: "de", probability: 0.999…), …]
detection.isTooCloseToCall  // false
```

### Kotlin

Tongue is a plain jar rather than an AAR, a pure Kotlin port with no native
libraries, so it also runs on a bare JVM (17+).

```kotlin
import ai.desertant.tongue.Tongue

// Android: pass the Context. On a bare JVM call Tongue.bundled().
val tongue = Tongue.bundled(context)
val detection = tongue.detect("kann ich das haben")
detection.language                               // "de"
detection.isTooCloseToCall                       // false
```

### JavaScript

One import everywhere: no wasm, no LiteRT.js, no native core.

```ts
import { Tongue } from "@desert-ant-labs/tongue";

const tongue = await Tongue.load();                    // Node: reads the bundled model
const detection = tongue.detect("kann ich das haben");
detection.language;                                    // "de"
detection.isTooCloseToCall;                            // false
```

In a browser, serve tongue's two model files yourself (a bundler does not serve
files out of `node_modules`) and pass `from`; both files are exported subpaths,
so a copy script can `require.resolve` them under pnpm and Yarn PnP too:

```ts
const tongue = await Tongue.load({ from: "/models/tongue" });
```

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `tongue_int8.bin` | Raw int8 + fp32 | 2.01 MiB | The shipped artifact. Byte-identical to what the live demo runs. |
| `tongue_int4.bin` | Raw int4 + fp32 | 1.01 MiB | Half-size alternative for tight bundles. Costs roughly 0.4pp on short text, see Sizes. |
| `tongue.onnx` | ONNX (fp32, opset 17) | 8.4 MB | Portable graph for onnxruntime / onnxruntime-web. |
| `tongue_meta.json` | JSON | tiny | Runtime tables: label order, hashing constants, script routing. |
| `labels.json` | JSON | tiny | The 59 model labels plus the script-decided languages, with English and native names. |

There is no tokenizer file, so nothing has to be shipped or version-matched
alongside the weights.

## Inputs and outputs

**Input:** a short UTF-8 string, up to 512 characters.
**Output:** ranked ISO 639-1/639-3 codes with probabilities, plus a reliability
signal (`confident` / `likely` / `tentative`). Script-decided inputs return a
single confident answer.

The ONNX graph carries **only the head**: `values` (int64 hashed bucket ids) and
`offsets` (int64 per-sample starts) in, `logits` out. Normalization, hashing and
script routing run in the host before the graph; `tongue_meta.json` documents them.

## Coverage

59 languages are learned by the lexical model and a further 25 are decided by
script alone, across 31 scripts (Latin, Cyrillic, Arabic, Greek and the CJK and
Indic families among them) for **84 languages** in total. One of the 84,
Mongolian, is detected only in the traditional Mongolian script; see failure
mode 3.

## Sizes

Two quantisations of the same weights ship side by side. Pick on bundle budget,
not on principle.

| | `tongue_int8.bin` | `tongue_int4.bin` |
|---|---|---|
| Size | 2.01 MiB | **1.01 MiB** |
| FLORES 2-word | 0.869 | 0.866 |
| FLORES 5-word | 0.974 | 0.973 |
| Held-out single words | 0.759 | 0.752 |
| Held-out sentences | 0.971 | 0.970 |

The int4 loss lands almost entirely on one- and two-word input; full sentences
are unaffected within measurement noise. Since short text is what this model is
for, int8 stays the default and int4 is the option when a megabyte matters more
than the last half point.

## Failure modes (read before deploying)

Publishing these is part of the product.

**1. One or two words is often genuinely undecidable, and no model size fixes
it.** A single common word frequently belongs to several languages at once
(`"sale"` is English, French and Italian; `"la casa"` is equally Italian and
Spanish). tongue reports a tie or a tentative answer in these cases. It does not
catch every one: a phrase mixing languages, like `"un garage sale"`, can still
draw a confident-looking single answer.
Mitigation: treat low-reliability output as "unknown", not as an answer, and ask
for more text where the product allows it.

**2. Malay and Indonesian are not reliably separable.** They share vocabulary
and orthography to the point where short samples carry no distinguishing
signal. This is a structural limit, not a tuning gap, and it is not cheaply
closable at this size, and every detector we measured struggles with it.
Mitigation: if you need the distinction, treat `ms`/`id` as one bucket or
disambiguate from user locale.

**3. Mongolian is detected only in the traditional Mongolian script.**
Mongolian written in Cyrillic, the dominant modern orthography, is not
distinguished from the other Cyrillic languages and will usually come back as
Russian. The language count includes Mongolian because the traditional script
works; Cyrillic Mongolian does not. Mitigation: do not rely on tongue for
Cyrillic Mongolian.

**4. Brand names, numbers and code are not language.** `"Samsung Galaxy"`,
`"v1.2.3"` and `"2024 annual report"` have no correct answer; the model will
still return its best guess for anything with letters in it. Mitigation: filter
non-prose input before detection.

**5. Single-word scores are vocabulary recognition, not generalization.** The
frequent words of a language appear in everyone's training data, so any
detector's single-word accuracy partly measures memorized vocabulary. Read the
word-pair and sentence numbers as the generalization signal.

## Measured quality

Every number below is measured on the shipped int8 weights, on three
public benchmarks, with other detectors run on the identical rows and language
subsets. Higher is better.

### FLORES-200

Sentences from FLORES-200 truncated to their first 2, 3 and 5 words. Accuracy
over the 20 languages the three detectors share.

| Detector | Size | 2 words | 3 words | 5 words |
|---|---|---|---|---|
| **tongue** | **2 MB** | **0.869** | **0.933** | **0.974** |
| lingua | 293 MB | 0.800 | 0.887 | 0.956 |
| eld | ~1 MB | 0.780 | 0.856 | 0.912 |

### The lingua test set, the benchmark that library publishes

1,000 single words, word pairs and sentences per language, drawn from the
same collection lingua trains on. Accuracy over the languages we share.

| Detector | Size | Single words | Word pairs | Sentences |
|---|---|---|---|---|
| **tongue** | **2 MB** | **0.746** | **0.909** | **0.988** |
| lingua | 293 MB | 0.752 | 0.915 | 0.985 |

### eld, an independent benchmark

Accuracy over the languages tongue supports (53,035 single-word rows,
53,613 word pairs, 53,141 sentences, 9,066 tweets).
Apple is the built-in system detector; HeLI-OTS is a 51 MB JVM model. lingua 2.2.0 installs as a
single 293 MB compiled extension with its language models embedded.

| Detector | Size | Tweets | Single words | Word pairs | Sentences |
|---|---|---|---|---|---|
| **tongue** | **2 MB** | **0.992** | **0.759** | **0.887** | **0.971** |
| lingua | 293 MB | 0.984 | 0.756 | 0.894 | 0.950 |
| HeLI-OTS | 51 MB | 0.986 | 0.683 | 0.843 | 0.967 |
| Apple | system | 0.997 | 0.641 | 0.719 | 0.748 |

## Latency

Measured per single detection in JavaScript on an Apple-silicon laptop: 0.013 ms for one word, 0.028 ms for a short sentence, 0.10 ms at 193 characters (p99 0.24 ms). On-device budgets on phone-class hardware will be higher; the design target is under 1 ms.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0).
Free for most apps; a commercial license is required at scale. Full terms at the
link. Licensing: <licensing@desertant.com>.
