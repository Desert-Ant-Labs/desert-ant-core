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
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.6.0")
```

Then add the `Emo` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:emo:3.6.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/emo @litertjs/core   # browser
npm i @desert-ant-labs/emo                  # Node, prebuilt native core
```
<!-- model:end -->

## Usage

Create one `Emo` instance and reuse it. Creating the instance is cheap and doesn't block. The SDK loads the model on first use, or earlier if you call `download`.

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

`suggestions` and `download` are suspending functions. An `Emo` holds native resources, so close it when you're done, or let `use { }` close it.

```kotlin
import ai.desertant.emo.Emo
import ai.desertant.emo.EmojiSkinTone

Emo(context).use { emo ->
    val suggestions = emo.suggestions("Pay my bills")               // List<EmoSuggestion>
    val toned = emo.suggestions("go for a run", limit = 1, skinTone = EmojiSkinTone.MEDIUM)
}
```

### JavaScript

The default import is the browser build. For inference in Node, import the `/native` subpath. The SDK ships `/native` prebuilt for linux-x64, linux-arm64 and darwin-arm64.

```ts
import { Emo } from "@desert-ant-labs/emo";           // browser
// import { Emo } from "@desert-ant-labs/emo/native"; // server-side Node

const emo = await Emo.load();                                // downloads and caches on first use
const suggestions = await emo.suggestions("Pay my bills");   // [{ emoji, confidence }, ...]
emo.dispose();
```

### Loading the model

The SDK downloads the weights from Hugging Face on first use and caches them. To download the weights earlier, for example during onboarding, or to ship them yourself, see [model downloads and caching](../../README.md#model-downloads-and-caching).

```swift
let emo = Emo()
if !emo.isDownloaded() {
    try await emo.download { fraction in print("\(Int(fraction * 100))%") }
}

let offline = Emo(directory: myModelDirectory)   // uses the files as they are, downloads nothing
```

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `emo.tflite` | LiteRT / TFLite (int8) | 10.2MB | Runs on Android, Linux, Windows, Node, and the web (downloaded on demand by the Kotlin and JavaScript SDKs) |
| `emo.mlmodelc` | Compiled Core ML | 4.6MB | Ready to load on Apple platforms (used by the Swift SDK) |
| `emo_tokenizer.bin` | Unigram tokenizer | 0.75MB | Tokenizer the runtime needs |
| `emo_meta.json` | JSON | tiny | Emoji labels and runtime config |

Older SDK versions load `Emo.mlmodelc` and `emo.safetensors`. Those files stay on Hugging Face in revisions `v0.6.0` and earlier.

## Inputs and outputs

Pass a plain text string. Emo works best on short text that states an intent, like "Pay my bills". Emo gives each of the 800 emoji in its vocabulary a probability. Show the top suggestion, or the top few.

## Languages

English, Spanish, Portuguese, French, German, Italian, Dutch, Russian, Polish, Turkish, Arabic, Chinese (Simplified and Traditional), Japanese, Korean, Hindi, Indonesian, Thai, Vietnamese, Ukrainian, Swedish, Danish, Czech.

## Limits

- Emo is tuned for short text that states an intent. Longer text gets noisier suggestions.
- Emoji meanings are imprecise. Expect near-ties between the top suggestions.
- Quality varies by language. Emo is somewhat weaker on the lower-resource languages in the set.

## License

Emo is available under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Most apps can use Emo for free. At scale, you need a commercial license. The link has the full terms. For licensing, email <licensing@desertant.com>.
