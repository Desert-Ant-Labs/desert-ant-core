<!-- model:start -->
# Voz

Transcribe 10 minutes in 2 seconds.

On-device speech recognition: transcripts with word-level timestamps, 25 languages.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Browser, Node |
| **Languages** | 25 |
| **Weights** | [v0.1.0](https://huggingface.co/desert-ant-labs/voz) |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.3.1")
```

Then add the `Voz` product to your target.

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/voz onnxruntime-web
```
<!-- model:end -->

## Usage

`Voz` turns speech into text, with a start and an end on every word. Create one
and reuse it; the model downloads on first use and is cached.

```swift
import Voz

let voz = try await Voz()
let result = try await voz.transcribe(url)

result.text                     // the transcript
result.words.first?.start       // 80 ms resolution
result.realtimeFactor           // seconds of audio per second of wall clock
```

Samples work too, mono at `voz.sampleRate`:

```swift
let result = try await voz.transcribe(samples: samples)
```

### Downloading ahead of time

The first load after a download pays a one-time Neural Engine specialization of
roughly 20 seconds; every load after it takes about 0.2 s. Doing both during
onboarding keeps that cost off the first transcription.

```swift
if !Voz.isDownloaded() {
    try await Voz.download { progress in
        show(progress.fraction)
    }
}
```

### Picking a language first

`Voz` covers 25 languages and does not detect which one it is hearing. Pair it
with [Ear](ear.md) when the input could be anything:

```swift
let detection = try await Ear().identify(contentsOf: url)
guard detection.isReliable, Voz.supportedLanguages.contains(detection.language ?? "") else {
    return try await yourFallbackRecognizer(url)   // Voz does not cover it
}
let result = try await Voz().transcribe(url)
```

The fallback is yours to choose: `Voz` ships the recognizer, not a router.

### JavaScript

The browser and Node run the same pipeline compiled to WebAssembly, over ONNX
Runtime rather than Core ML.

```js
import { Voz } from "@desert-ant-labs/voz";

const voz = await Voz.load();
const result = await voz.transcribe(file);   // File, Blob, ArrayBuffer, or samples

result.text;
result.words[0];        // { text: "chapter", start: 0.08, end: 0.24 }
result.realtimeFactor;
```

The encoder runs on WebGPU, and on a browser that exposes WebNN (Chromium
today) the decode step runs on the Neural Engine. `onnxruntime-web` is imported
on demand, as LiteRT.js is for the other models here, so installing it is all a
browser app does.

A `File` is read in pieces as the model works through it, so memory does not
grow with the length of the recording: a five-hour file costs what a
five-minute one does. Ten minutes of audio runs at about 125x real time in
Chromium on an M5, 38x on an M1 and 35x in Safari, at a word error rate level
with the Core ML build.

Under Node, install `onnxruntime-node` and pass it to `load({ ort })`: same API
and the same word timestamps, on the CPU. It is not imported for you there
because a native addon in the module graph cannot be bundled for a server.

A `File` is decoded for you, with Web Audio in the browser and the portable WAV
codec in Node. See the
[package README](../../packages/voz-node/README.md) for the load options, the
self-hosting path, and the browser requirements.

## Accuracy

| | |
|---|---|
| Speed | 2.1 s for 611 s of audio (about 290x real time) on long files |
| Word error rate | 7.40% over six Open ASR Leaderboard sets, against 7.00% for Whisper large-v3-turbo |
| Long-form | 2.83% on half an hour of narration, against 2.72% for the same Whisper |
| Word timestamps | starts 83 ms, ends 95 ms mean absolute error against a forced aligner |
| Neural Engine | 100% resident, no CPU or GPU fallback |
| Size | 467 MB, against 1.6 GB for Whisper large-v3-turbo |

Close to a model three and a half times its size, two points better on meetings,
behind on prepared and read speech.

**Expect the conversational figures, not the LibriSpeech one.** Read speech in a
clean recording scores around 2%; meetings, earnings calls and podcast audio
score 10-13%, and most real material is nearer the second group. Roughly one word
in ten wanting a look is the honest expectation for a podcast.

Per-language figures on long audio, and the full leaderboard breakdown, are in
the [model card](https://huggingface.co/desert-ant-labs/voz).

## Limits

- **Apple platforms and the browser.** On Apple the runtime drives Core ML
  directly, because the things that make it fast (preallocated buffers,
  `outputBackings`, a lane-batched decode loop) are not expressible through the
  generic inference shape the other models share. The JavaScript SDK runs the
  same pipeline on ONNX Runtime, in a browser or in Node. There is no Android
  or Linux build.
- **The browser bundle is a separate download**: 390 MB, because a GPU wants the
  weights in a different layout than the Neural Engine does. Resident cost is
  about 1.2 GB, most of it what ONNX Runtime keeps for the compiled session
  rather than the weights themselves. Tested on Chromium 135+ and Safari 26+.
- **Node transcribes on the CPU.** `onnxruntime-node`'s default execution
  provider reaches no accelerator, so a server is slower per second of audio
  than a browser on the same machine.
- **25 languages**, and it does not know which one it is hearing. Feeding it a
  language it does not cover produces confident nonsense rather than an error.
  See [Ear](ear.md).
- **Accuracy varies widely by language.** Italian is 3.31% and Greek 39.46% on
  the same ten-minute-per-language protocol. Check the model card before
  promising a language.
- **Word ends are the harder half.** The recognizer reports how far to skip after
  each token rather than where a word stops, so ends are trimmed back using the
  audio. 80 ms is the frame resolution and the floor for any timestamp here.
- **467 MB** is a real download. Fetch it during onboarding, not on first use.
