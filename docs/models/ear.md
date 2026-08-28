<!-- model:start -->
# Ear

Name the language from thirty seconds of audio.

On-device spoken language identification across 99 languages.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Languages** | 99 |
| **Weights** | [v0.1.0](https://huggingface.co/desert-ant-labs/ear) |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.1.0")
```

Then add the `Ear` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:ear:3.1.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/ear @litertjs/core   # browser
npm i @desert-ant-labs/ear                  # Node, prebuilt native core
```
<!-- model:end -->

## Usage

`Ear` names the language of a recording, so an app can pick the right recognizer
before it starts transcribing. It listens to three thirty-second windows rather
than the whole file, which takes about 250 ms.

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

Create one and reuse it. Construction does no work and starts no download; the
model loads on the first `identify` or `download(progress:)`, off your calling
thread.

Already-decoded audio at any rate works too:

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

One import for the browser (WebAssembly + LiteRT.js) and Node (prebuilt native
core); the runtime resolves the right one.

```js
import { Ear } from "@desert-ant-labs/ear";

const ear = await Ear.load();
const detection = await ear.identify(samples, 16000);

detection.language      // "pt"
detection.isReliable    // true
ear.dispose();
```

### Deciding what to do with the answer

`isReliable` is the flag to branch on. It is false when the top two candidates
are too close to separate, and false for Norwegian, Swedish and Danish, which
the model confuses with each other confidently rather than uncertainly - so
their probability does not reveal the problem.

```swift
guard detection.isReliable, let language = detection.language else {
    return await transcribeWithFallback(url)     // ask, or use a general model
}
```

`isReliable` is decided once, in the model, and crosses the boundary as a
number. Every SDK reads the same flag rather than reimplementing the rule, which
is measured rather than obvious.

The threshold was set by sweeping it against 162 recordings. Of the answers
above it, 98.5% route correctly; on files in a language the primary recognizer
supports, 100% do, and 86% of files clear it.

### Downloading ahead of time

```swift
if !Ear.isDownloaded() {
    try await ear.download { fraction in print(fraction) }
}
```

`directory` points at model files you manage yourself. If it already holds the
model it is used offline and nothing is downloaded, which is how you ship the
weights inside an app instead of fetching them.

```swift
let ear = Ear(directory: "/path/to/model")
```

## What it hears

A file handed to a transcriber is not speech end to end, so `Ear` does not
listen to it end to end either. It ranks candidate windows by how much of their
loudness varies at syllable rate - speech rises and falls three to six times a
second and has gaps between words, music sustains, silence does not vary at all
- and listens to the three most speech-like.

That matters more than it sounds. Picking windows by position finds the language
4% of the time on a five-minute recording with speech in a tenth of it. Picking
the loudest windows finds it half the time on a file with a music intro, because
an intro is mixed hotter than the voice after it.

## Accuracy

Measured end to end through this SDK, on real uploads:

| | exact | confident | of those, right |
| --- | ---: | ---: | ---: |
| Ordinary recordings | 12/12 | 12/12 | **12/12** |
| The same, rebuilt as podcasts | 9/10 | 8/10 | **8/8** |

No confident answer was wrong in either set. The podcast miss is a German
episode read as English under its jingle, and it was reported unsure.

## Limits

- **Speech mixed under louder music** is read correctly about 60% of the time.
  No amount of choosing better windows changes that; the model cannot read it.
- **Nordic languages** are not distinguished reliably. `isReliable` is false for
  all of them rather than reporting one confidently.
- **Recordings shorter than thirty seconds** get a single window, so there is
  nothing to average and the answer is less certain than the number suggests.
- Multilingual recordings are reported as whichever language the chosen windows
  contain, not as a mixture.
