<!-- model:start -->
# Ear

Detect spoken language from 30 seconds audio.

On-device spoken language identification across 102 languages.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Languages** | 102 |
| **Weights** | [v0.2.0](https://huggingface.co/desert-ant-labs/ear/tree/v0.2.0) |
<!-- model:end -->

Detect the spoken language of a recording with Ear before you transcribe it, so you run the right transcription model. Ear works on 5-30s of speech and takes 7.6ms on a MacBook Pro, entirely on the device.

Ear is a spoken language identification model for 102 languages. Ear gives each language a confidence score. When the top two are too close to call, Ear flags the answer as unreliable. You can then ask the user or fall back to a general model instead of transcribing in the wrong language. The model is 5.0MB as Core ML for Apple platforms and 10.7MB as LiteRT for Android, Linux, Windows and Node.

<!-- model-install:start -->
## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.2.3")
```

Then add the `Ear` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:ear:4.2.3")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/ear @litertjs/core   # browser
npm i @desert-ant-labs/ear                  # Node, prebuilt native core
```
<!-- model-install:end -->

## Usage

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

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `ear.mlmodelc` | Core ML, 6-bit weights, compiled | 5.0MB | The detector for iOS, macOS, tvOS and visionOS |
| `ear.tflite` | LiteRT, int8 | 10.7MB | The detector for Android, Linux, Windows, Node and the web |
| `ear_meta.json` | JSON | 2.2kB | The front end's geometry and the tensor names per runtime |
| `languages.json` | JSON | 0.6kB | The language codes, in output order |
| `mel_filters.f32` | Binary table | 64kB | The mel filterbank, 80 by 201, little-endian |

Load the detector for your platform together with `ear_meta.json`, `languages.json` and `mel_filters.f32`. The SDK uses them to prepare the audio, so there's no separate model for that step.

## Inputs and outputs

- **In:** 16kHz mono audio, up to 30s.
- **Out:** a probability for each language, in the order of `languages.json`. The language with the highest probability is Ear's answer.
- **Reliable or not:** an answer is reliable when the top two probabilities are at least 0.25 apart. The SDK always marks Norwegian, Swedish and Danish as unreliable.

## Languages

Ear covers 102 languages, from Afrikaans to Zulu, listed in output order in `languages.json`. For any other language, Ear returns the closest supported language, so check that each answer is reliable before picking a transcription model.

## Results

**The right transcription model, 99% of the time.** Measured on the published weights, with speakers who weren't in the training data.

**Accuracy by clip length.** How often Ear's top answer is the right language.

| Corpus | Clips per length | 5s | 10s | 15s | 20s | 30s |
|---|---:|---:|---:|---:|---:|---:|
| Common Voice, 15 languages | 1,500 | 0.946 | 0.980 | 0.989 | 0.991 | 0.995 |
| VoxPopuli, 16 languages | 825 to 458 | 0.978 | 0.996 | 0.997 | 0.998 | 1.000 |
| NST, Norwegian and Swedish | 200 | 0.985 | 0.995 | 1.000 | 1.000 | 1.000 |
| Multilingual LibriSpeech, 7 languages | 532 | 0.979 | 0.992 | 0.996 | 0.998 | 0.994 |
| English, LibriSpeech audiobooks | 100 | 0.990 | 1.000 | 1.000 | 1.000 | 1.000 |
| English, AMI meetings | 100 | 0.950 | 1.000 | 1.000 | 1.000 | 1.000 |
| English, CHiME-6 dinner parties | 32 | 0.938 | 1.000 | 1.000 | 1.000 | 1.000 |
| English, NOTSOFAR-1 meetings | 100 | 0.900 | 0.890 | 0.960 | 0.960 | 0.980 |

**Routing, every clip.** Right model: the clip went to a transcription model that handles its language. Wrong model: it went to one that doesn't. Reliable: the answer passed the reliability rule. Right when reliable: how many reliable answers were correct.

| Corpus | Clips | Right model | Wrong model | Reliable | Right when reliable |
|---|---:|---:|---:|---:|---:|
| Common Voice | 7,500 | 0.990 | 0.014 | 0.986 | 0.994 |
| VoxPopuli | 3,221 | 0.998 | 0.000 | 0.995 | 0.999 |
| NST | 1,000 | 1.000 | 0.000 | always unreliable | |
| Multilingual LibriSpeech | 2,660 | 0.997 | every language handled | 0.994 | 0.998 |
| English, four conditions | 1,660 | 0.980 | every language handled | 0.972 | 0.991 |

**Whole recordings.** Ear's answers on three 30s clips from each recording, averaged.

| Corpus | Recordings | Right model | Reliable | Right when reliable | Reliable and wrong |
|---|---:|---:|---:|---:|---:|
| Common Voice | 457 | 0.993 | 0.996 | 0.996 | 2 |
| VoxPopuli | 256 | 1.000 | 1.000 | 1.000 | 0 |
| NST | 80 | 1.000 | always unreliable | | 0 |
| Multilingual LibriSpeech | 173 | 1.000 | 1.000 | 1.000 | 0 |
| English, four conditions | 128 | 0.984 | 0.984 | 0.992 | 1 |

**More test sets, Core ML build.**

| Set | Clips | Accuracy | Right model | Wrong model |
|---|---:|---:|---:|---:|
| FLEURS test, the 32 product languages | 640 | 0.977 | 0.997 | 0.000 |
| FLEURS test, all 102 languages | 2,040 | 0.954 | 0.993 | 0.010 |
| VoxLingua107 dev, YouTube audio, languages Ear offers | 1,094 | 0.942 | 0.973 | |
| VoxLingua107 dev, YouTube audio, languages Ear does not offer | 515 | | | 0.012 |
| 120 VoxPopuli recordings, whole files | 120 | | 1.000 | |

## Performance

**7.6ms per clip on the Apple Neural Engine.** One 30s clip, after warm-up, median.

| Build | Device | Compute | Size | Latency |
|---|---|---|---:|---:|
| Core ML, 6-bit weights | MacBook Pro, M5 Pro, macOS 26 | Apple Neural Engine, 100% resident | 5.0MB | 7.6ms |
| LiteRT, int8 | MacBook Pro, M5 Pro, macOS 26 | CPU, 4 threads | 10.7MB | 26.8ms |

## Limitations

- **Far-field recordings.** Ear is less accurate when the speakers are far from the microphone. On NOTSOFAR-1 meetings, Ear gets the language right 90% of the time on 5s clips, versus 98% on 30s clips. For room recordings, pass Ear the full 30s, and when an answer is unreliable, ask a user to confirm the language.
- **Galician.** Ear labels Galician as Spanish about 4% of the time.
- **Norwegian, Swedish and Danish.** Ear tells Norwegian and Swedish apart 98.5-100% of the time on NST. The SDK still marks all three as unreliable, so you can route them to a transcription model that handles them well.
- **Mixed-language recordings.** Ear returns one language per clip, even if the speakers switch languages.
- **Languages outside the 102.** Ear returns the closest supported language. The reliability rule catches most of these answers, but not all of them.
- Ear detects the language and doesn't transcribe. For a transcript, pair Ear with Voz or another transcription model.

## Built on

Open models and tools this work builds on, with their licenses:

- [openai/whisper-tiny](https://huggingface.co/openai/whisper-tiny), Apache-2.0

None of them is redistributed here. Dataset attributions are in the weights' third-party notices, linked under License.

<!-- model-footer:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

Third-party notices for the weights: [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/ear/blob/main/THIRD_PARTY_NOTICES.md).

## Citation

```bibtex
@software{ear_2026,
  title  = {Ear: On-device spoken language identification across 102 languages},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/ear},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
<!-- model-footer:end -->
