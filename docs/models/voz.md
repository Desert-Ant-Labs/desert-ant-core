<!-- model:start -->
# Voz

Transcribe 10 minutes in 2 seconds.

On-device speech recognition: transcripts with word-level timestamps, 25 languages.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Languages** | 25 |
| **Weights** | [v0.4.0](https://huggingface.co/desert-ant-labs/voz) |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.0.0")
```

Then add the `Voz` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:voz:4.0.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/voz onnxruntime-web
```
<!-- model:end -->

## Usage

Create one `Voz` instance and reuse it. The SDK downloads the model the first time you use it and keeps it on the device.

### Swift

```swift
import Voz

let voz = try await Voz()
let result = try await voz.transcribe(url)

result.text                     // the transcript
result.words.first?.start       // in seconds, 80ms resolution
result.realtimeFactor           // how many times faster than realtime
```

You can also pass raw samples, mono at `voz.sampleRate`:

```swift
let result = try await voz.transcribe(samples: samples)
```

### Kotlin

```kotlin
val voz = Voz(context)                       // downloads on first use
val t = voz.transcribe(samples, 16_000.0)

t.text                    // the transcript
t.words.first().start     // 80 ms resolution
voz.close()
```

On Android the graphs run through LiteRT: XNNPACK on the CPU, or the GPU when its accelerator library is bundled with the app. Expect real-time factors far below the Neural Engine's. Transcribe off the main thread, and keep the recognizer around instead of recreating it.

### Names and jargon

Pass names and terms the audio is likely to contain, cased as they should be written:

```swift
let result = try await voz.transcribe(url, vocabulary: ["SoFi", "Timex", "Patek Philippe"])
```

Voz prefers these spellings where it was close to choosing them anyway ("SoFi" over "Sophie"). It never adds words that weren't spoken. Keep the list relevant to the recording, such as meeting participants or a video's title and description: a long generic list makes transcripts worse. Live sessions take the same list in `LiveConfiguration.vocabulary`. Not available in JavaScript yet.

### Downloading ahead of time

On Apple platforms, the first load after a download typically takes 10-30s, depending on the device, while Core ML prepares the model for the Neural Engine. After that, a load takes 0.2s. Download and load the model during onboarding so your users don't wait on their first transcription.

```swift
if !Voz.isDownloaded() {
    try await Voz.download { progress in
        show(progress.fraction)
    }
}
```

```kotlin
if (!voz.isDownloaded()) voz.download()
```

### Picking a language first

Voz supports 25 languages. Voz doesn't detect the language of the audio. When the audio could be in any language, check it with [Ear](ear.md) first:

```swift
let detection = try await Ear().identify(contentsOf: url)
guard detection.isReliable, Voz.supportedLanguages.contains(detection.language ?? "") else {
    return try await yourFallbackRecognizer(url)   // unreliable detection, or a language Voz doesn't support
}
let result = try await Voz().transcribe(url)
```

### Windows

On Windows the Swift SDK runs Voz on the GPU, through ONNX Runtime and DirectML. The API is the same as on Apple platforms.

### JavaScript

In the browser and in Node, Voz runs the same pipeline as the Swift SDK, compiled to WebAssembly, on ONNX Runtime instead of Core ML.

```js
import { Voz } from "@desert-ant-labs/voz";

const voz = await Voz.load();
const result = await voz.transcribe(file);   // File, Blob, ArrayBuffer, or samples

result.text;
result.words[0];        // { text: "chapter", start: 0.08, end: 0.24 }
result.realtimeFactor;
```

In the browser the encoder runs on WebGPU. When the browser supports WebNN, as Chromium on a Mac does, the decoder runs on the Neural Engine. The SDK loads `onnxruntime-web` when it needs it, so you only have to install the package.

Voz reads a `File` in pieces, so a five-hour recording needs no more memory than a five-minute one. In Chromium, Voz transcribes 10 minutes of audio at 125x realtime on an M5 and 38x on an M1. Safari runs at 35x. The word error rate matches the Core ML build.

In Node, install `onnxruntime-node` and pass it to `load({ ort })`. You get the same API and the same word-level timestamps, running on the CPU. The SDK doesn't import `onnxruntime-node` for you, because a server bundle can't include a native addon.

The SDK streams WAV directly and decodes other formats with WebCodecs. In Node without WebCodecs, convert the audio to WAV first. For load options, self-hosting and browser requirements, see the [JavaScript package docs](../../packages/voz-node/README.md).

## Performance

We timed 10 minutes of audio on the Neural Engine and kept the fastest of three runs after the model loaded:

| Device | Time | Realtime factor |
|---|---:|---:|
| M3 Ultra | 0.72s | **828x** |
| M6 | 0.84s | **718x** |
| iPhone 18 Pro | 0.98s | **615x** |
| M5 | 1.15s | **520x** |

Short clips run slower than long files. On an M3 Ultra, a 5s clip takes 38ms (130x) and a 10s clip 48ms (210x).

On Apple platforms, Voz runs entirely on the Neural Engine, so your app keeps the GPU and CPU. On Windows, Voz runs on the GPU.

## Accuracy

| | |
|---|---|
| Word error rate | 6.43% across six Open ASR Leaderboard datasets. Whisper large-v3-turbo scores 7.00%. |
| On long audio | 2.48% on 5.4 hours of whole audiobook chapters. |
| Word timestamps | Starts are off by 80ms and ends by 77ms on average, compared with a forced aligner. |
| Size | 337MB. Whisper large-v3-turbo is 1.6GB. |

Voz scores better than Whisper large-v3-turbo at a fifth of the size. Voz scores four points better on meetings, about the same on podcasts and earnings calls, and worse on prepared financial speech.

Clean audiobook recordings score around 2%. Meetings, earnings calls and podcasts score 8-11%. Most real recordings sound more like those. On a podcast, plan to check one word in ten.

The [model card](https://huggingface.co/desert-ant-labs/voz) has the accuracy for each language on long audio and the full leaderboard results.

## Limits

- On Android and Linux, Voz runs through LiteRT, not through the generic inference path our other models share. The decode loop needs preallocated buffers and lane batching, which that path can't express.
- The speed figures above are from the Neural Engine. They don't transfer to LiteRT on a phone CPU. Measure on your target device before you promise real-time factors.
- In the browser, Voz needs its own 409MB download, because a GPU needs the weights in a different layout than the Neural Engine. Voz uses 1.2GB of memory in the browser, mostly for ONNX Runtime's compiled session. We test on Chromium 135+ and Safari 26+.
- In Node, Voz runs on the CPU. `onnxruntime-node` doesn't use the GPU by default, so a server transcribes slower than a browser on the same machine.
- Voz doesn't detect the language. Audio in a language Voz doesn't support comes back as fluent text that's wrong. Voz doesn't raise an error. Use [Ear](ear.md) to check first.
- Accuracy depends on the language. Italian scores 5.05% and Greek 36.60% on the FLEURS test set. Check the [model card](https://huggingface.co/desert-ant-labs/voz) before you promise a language to your users.
- Word ends are less precise than word starts. Voz marks where each word starts. The SDK estimates where each word ends from the audio. Timestamps land on 80ms frames, so no timestamp is more precise than 80ms.
- The model is 337MB. Download the model during onboarding, not on first use.

## License

Voz is available under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Most apps can use Voz for free. At scale, you need a commercial license. The link has the full terms. For licensing, email <licensing@desertant.com>.
