<!-- model:start -->
# Ear

Detect spoken language from 30 seconds audio.

On-device spoken language identification across 102 languages.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Languages** | 102 |
| **Weights** | [v0.2.0](https://huggingface.co/desert-ant-labs/ear) |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.1.0")
```

Then add the `Ear` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:ear:4.1.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/ear @litertjs/core   # browser
npm i @desert-ant-labs/ear                  # Node, prebuilt native core
```
<!-- model:end -->

## Usage

Ear detects the language of a recording, so your app can pick the right recognizer before transcription starts. Ear analyzes three 30s windows instead of the whole file. Each window takes 7.6ms on the Neural Engine of a MacBook Pro.

### Swift

```swift
import Ear

let ear = Ear()                                     // downloads on first use
let detection = try await ear.identify(contentsOf: url)

detection.language      // "pt"
detection.confidence    // 0.98
detection.isReliable    // true
detection.candidates    // [LanguagePrediction(language: "pt", probability: 0.98), …]
```

Create one `Ear` instance and reuse it. Creating the instance does no work and starts no download. The SDK loads the model on the first call to `identify` or `download(progress:)`, off your calling thread.

You can also pass decoded samples at any sample rate:

```swift
let detection = try await ear.identify(samples: samples, sampleRate: 44100)
```

### Kotlin

```kotlin
val ear = Ear(context)                         // downloads on first use
val detection = ear.identify(samples, 16_000.0)

detection.language      // "pt"
detection.confidence    // 0.98
detection.isReliable    // true
ear.close()
```

### JavaScript

The default import is the browser build, which runs on WebAssembly and LiteRT.js. For inference in Node, import the `/native` subpath, which runs a prebuilt native core.

```js
import { Ear } from "@desert-ant-labs/ear";           // browser
// import { Ear } from "@desert-ant-labs/ear/native"; // server-side Node

const ear = await Ear.load();
const detection = await ear.identify(samples, 16000);

detection.language      // "pt"
detection.isReliable    // true
ear.dispose();
```

### Deciding what to do with the answer

Branch on `isReliable`. `isReliable` is false when the top two candidates are less than 0.25 apart. `isReliable` is also always false for Norwegian, Swedish and Danish. Ear tells Norwegian and Swedish apart 98.5-100% of the time, but the SDK marks all three as unreliable so you can route them to a recognizer that handles them well.

```swift
guard detection.isReliable, let language = detection.language else {
    return await transcribeWithFallback(url)     // ask, or use a general model
}
```

Every SDK reads `isReliable` from the same shared core, so the same recording gets the same answer on every platform.

Most answers are reliable, and reliable answers are almost always right:

| Corpus | Clips | Reliable | Right when reliable |
| --- | ---: | ---: | ---: |
| Common Voice | 7,500 | 98.6% | 99.4% |
| VoxPopuli | 3,221 | 99.5% | 99.9% |
| Multilingual LibriSpeech | 2,660 | 99.4% | 99.8% |
| English, four recording conditions | 1,660 | 97.2% | 99.1% |

### Downloading ahead of time

```swift
if !Ear.isDownloaded() {
    try await ear.download { fraction in print(fraction) }
}
```

Pass `directory` to use model files you manage yourself. When the directory already holds the model, Ear loads the model offline and downloads nothing. Use `directory` to ship the weights inside your app instead of fetching them.

```swift
let ear = Ear(directory: "/path/to/model")
```

## How Ear picks windows

Most recordings aren't speech from start to end, so Ear doesn't analyze the whole file. Ear ranks candidate windows by how much of their loudness varies at syllable rate, and analyzes the three most speech-like windows. Speech rises and falls three to six times a second and has gaps between words. Music sustains notes. Silence doesn't vary at all.

## Accuracy

Ear sends a recording to the right transcription model 99% of the time: a model that handles the recording's language. We measured Ear on speakers who weren't in the training data.

How often Ear's top answer is the right language, by clip length:

| Corpus | 5s | 10s | 30s |
| --- | ---: | ---: | ---: |
| Common Voice, 15 languages | 94.6% | 98.0% | 99.5% |
| VoxPopuli, 16 languages | 97.8% | 99.6% | 100% |
| Multilingual LibriSpeech, 7 languages | 97.9% | 99.2% | 99.4% |
| English, NOTSOFAR-1 meetings | 90.0% | 89.0% | 98.0% |

Whole recordings, three 30s windows each:

| Corpus | Recordings | Right model | Reliable | Right when reliable |
| --- | ---: | ---: | ---: | ---: |
| Common Voice | 457 | 99.3% | 99.6% | 99.6% |
| VoxPopuli | 256 | 100% | 100% | 100% |
| Multilingual LibriSpeech | 173 | 100% | 100% | 100% |
| English, four recording conditions | 128 | 98.4% | 98.4% | 99.2% |

The full tables are on the [model card](https://huggingface.co/desert-ant-labs/ear).

## Limits

- Ear is less accurate when the speakers are far from the microphone. On NOTSOFAR-1 meetings, Ear finds the language 90% of the time on 5s clips, versus 98% on 30s clips. For room recordings, pass Ear the full 30s.
- Ear labels Galician as Spanish about 4% of the time.
- Ear reports a multilingual recording as the language of the chosen windows. Ear doesn't report a mixture of languages.
- For a language outside the 102, Ear returns the closest supported language. `isReliable` catches most of these answers, but not all of them.

## License

Ear is available under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Most apps can use Ear for free. At scale, you need a commercial license. The link has the full terms. For licensing, email <licensing@desertant.com>.
