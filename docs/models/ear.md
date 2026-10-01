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
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.5.0")
```

Then add the `Ear` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:ear:3.5.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/ear @litertjs/core   # browser
npm i @desert-ant-labs/ear                  # Node, prebuilt native core
```
<!-- model:end -->

## Usage

Ear detects the language of a recording, so your app can pick the right recognizer before transcription starts. Ear analyzes three 30s windows instead of the whole file. Detection takes 250ms.

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

Branch on `isReliable`. `isReliable` is false when the top two candidates are too close to separate. `isReliable` is also false for Norwegian, Swedish and Danish. Ear confuses those three with each other at high confidence, so their probability doesn't show the error.

```swift
guard detection.isReliable, let language = detection.language else {
    return await transcribeWithFallback(url)     // ask, or use a general model
}
```

Every SDK reads `isReliable` from the same shared core, so the same recording gets the same answer on every platform.

We set the threshold by sweeping it against 162 recordings. 98.5% of the answers above the threshold route correctly. On files in a language the primary recognizer supports, 100% of those answers route correctly, and 86% of files clear the threshold.

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

Windows picked by position find the language 4% of the time on a five-minute recording with speech in a tenth of it. The loudest windows find the language 50% of the time on a file with a music intro and outro. An intro is mixed louder than the voice after it, so ranking by loudness picks the music.

## Accuracy

We measured Ear end to end through the SDK, on real uploads:

| | exact | confident | of those, right |
| --- | ---: | ---: | ---: |
| Ordinary recordings | 12/12 | 12/12 | **12/12** |
| The same, rebuilt as podcasts | 9/10 | 8/10 | **8/8** |

Ear gave no wrong confident answer in either set. The podcast miss is a German episode that Ear identified as English under its jingle. Ear marked that answer as unreliable.

## Limits

- Ear identifies speech mixed under louder music correctly 60% of the time. Better window selection doesn't change that, because the errors come from the model itself.
- Ear doesn't reliably tell Norwegian, Swedish and Danish apart. `isReliable` is false for all three, even when Ear reports one of them at high confidence.
- Ear analyzes a recording shorter than 30s as a single window. With nothing to average, the answer is less certain than the confidence suggests.
- Ear reports a multilingual recording as the language of the chosen windows. Ear doesn't report a mixture of languages.

## License

Ear is available under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Most apps can use Ear for free. At scale, you need a commercial license. The link has the full terms. For licensing, email <licensing@desertant.com>.
