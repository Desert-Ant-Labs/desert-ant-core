<!-- model:start -->
# Voz

Transcribe 10 minutes in 2 seconds.

On-device speech recognition: transcripts with word-level timestamps, 25 languages.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Windows, Browser, Node |
| **Languages** | 25 |
| **Weights** | [v0.3.0](https://huggingface.co/desert-ant-labs/voz) |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.6.0")
```

Then add the `Voz` product to your target.

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/voz onnxruntime-web
```
<!-- model:end -->

## Usage

Create one `Voz` instance and reuse it. The SDK downloads the model the first time you use it and keeps it on the device.

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

### Downloading ahead of time

On Apple platforms, the first load after a download typically takes 10-30s, depending on the device, while Core ML prepares the model for the Neural Engine. After that, a load takes 0.2s. Download and load the model during onboarding so your users don't wait on their first transcription.

```swift
if !Voz.isDownloaded() {
    try await Voz.download { progress in
        show(progress.fraction)
    }
}
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

We timed 10 minutes of audio on the Neural Engine of each Apple device with SDK 3.5.0 and kept the fastest of three runs after the model loaded:

| Device | Time | Realtime factor |
|---|---:|---:|
| M3 Ultra | 0.8s | **762x** |
| iPhone 18 Pro | 1.2s | **492x** |
| M4 Max | 1.3s | **453x** |
| iPhone 17 Pro | 1.8s | **334x** |
| iPhone 15 Pro | 2.1s | **283x** |
| M1 Mac mini | 2.4s | **251x** |

On Apple platforms, short clips run at 50-62x, because Voz always processes a full 15s window.

On Apple platforms, Voz runs entirely on the Neural Engine, so your app keeps the GPU and CPU. On Windows, Voz runs on the GPU.

## Accuracy

| | |
|---|---|
| Word error rate | 7.40% across six Open ASR Leaderboard datasets. Whisper large-v3-turbo scores 7.00%. |
| On long audio | 2.83% on 30 minutes of an audiobook. Whisper large-v3-turbo scores 2.72%. |
| Word timestamps | Starts are off by 83ms and ends by 95ms on average, compared with a forced aligner. |
| Size | 467MB. Whisper large-v3-turbo is 1.6GB. |

Voz comes close to Whisper large-v3-turbo at less than a third of the size. Voz scores two points better on meetings and worse on read and prepared speech.

Clean audiobook recordings score under 3%. Meetings, earnings calls and podcasts score 10-13%. Most real recordings sound more like those. On a podcast, plan to check one word in ten.

The [model card](https://huggingface.co/desert-ant-labs/voz) has the accuracy for each language on long audio and the full leaderboard results.

## Limits

- Voz has no Android SDK, and the Swift package doesn't run Voz on Linux. Voz runs on Apple platforms, Windows, in the browser and in Node. Voz doesn't use LiteRT, the runtime behind our other models on Android and Linux, because LiteRT can't preallocate buffers or batch the decode loop, and Voz would run slower.
- In the browser, Voz needs its own 390MB download, because a GPU needs the weights in a different layout than the Neural Engine. Voz uses 1.2GB of memory in the browser, mostly for ONNX Runtime's compiled session. We test on Chromium 135+ and Safari 26+.
- In Node, Voz runs on the CPU. `onnxruntime-node` doesn't use the GPU by default, so a server transcribes slower than a browser on the same machine.
- Voz doesn't detect the language. Audio in a language Voz doesn't support comes back as fluent text that's wrong. Voz doesn't raise an error. Use [Ear](ear.md) to check first.
- Accuracy depends on the language. Italian scores 3.31% and Greek 39.46%, on 10 minutes of audio per language. Check the [model card](https://huggingface.co/desert-ant-labs/voz) before you promise a language to your users.
- Word ends are less precise than word starts. Voz marks where each word starts. The SDK estimates where each word ends from the audio. Timestamps land on 80ms frames, so no timestamp is more precise than 80ms.
- The model is 467MB. Download the model during onboarding, not on first use.

## License

Voz is available under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Most apps can use Voz for free. At scale, you need a commercial license. The link has the full terms. For licensing, email <licensing@desertant.com>.
