<!-- model:start -->
# Who

Label who said what in audio and video.

On-device speaker labeling: per-person turns with timestamps.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Weights** | [v0.3.4](https://huggingface.co/desert-ant-labs/who/tree/v0.3.4) |
| **Demo** | https://desertant.com/models/who/ |
| **Status** | Beta |
<!-- model:end -->

Label the speakers in a recording and see exactly when each person starts and stops talking. A 50-minute interview takes 3s on a MacBook Pro, entirely on the device.

Use the timestamps to label a transcript by speaker, jump to the next time a guest talks, or cut every time the speaker changes. Who is a speaker diarization model made for podcasts, interviews, calls and meetings, and handles recordings of any length.

Who numbers the speakers in the order they first speak, and when two people talk at once, Who marks both of them. Who processes each five-minute section in one pass and matches voices across sections. Who runs on the Neural Engine on Apple platforms, through LiteRT on Linux, Windows and Android, and through WebAssembly in the browser and Node. There's also an ONNX build. The Core ML download is 81MB as float16 or 42MB with 8-bit weights, and both builds have the same error rate on AMI meetings, 12.6%.

<!-- model-install:start -->
## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.2.2")
```

Then add the `Who` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:who:4.2.2")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/who @litertjs/core   # browser
npm i @desert-ant-labs/who                  # Node, prebuilt native core
```
<!-- model-install:end -->

## Usage

### Swift

```swift
import Who

let who = Who()                                        // downloads on first use
let result = try await who.diarize(contentsOf: url)

result.speakerCount        // 3
for turn in result.turns {
    turn.speaker           // 0, 1, 2: numbered in order of first appearance
    turn.start             // 12.4, seconds from the start
    turn.end               // 15.9
}
```

Create one `Who` instance and reuse it. Creating the instance does no work and starts no download. The SDK loads the model on the first call to `diarize` or `download(progress:)`, off your calling thread.

You can also pass decoded mono samples at any sample rate:

```swift
let result = try await who.diarize(samples: samples, sampleRate: 48000)
```

### Kotlin

```kotlin
val who = Who(context)                       // downloads on first use
val result = who.diarize(samples, 16_000.0)

result.speakerCount                          // 3
for (turn in result.turns) {
    turn.speaker                             // 0, 1, 2: numbered in order of first appearance
    turn.start                               // 12.4, seconds from the start
    turn.end                                 // 15.9
}
who.close()
```

On Android the graphs run through LiteRT on the CPU, the 8-bit build, 32 MB. Create one `Who` and reuse it; `diarize` suspends on a background dispatcher. `result.keepingSpeakers(minimumShare = 0.05)` drops the speakers under a share of the recording, a laugh or a jingle that got a number of its own, as the Swift SDK's `keepingSpeakers(minimumShare:)` does.

### JavaScript

```ts
import { Who } from "@desert-ant-labs/who";           // browser
// import { Who } from "@desert-ant-labs/who/native"; // server-side Node

const who = await Who.load();                          // downloads on first use
const result = await who.diarize(file);                // a File or Blob, the bytes of an audio file, or samples

result.speakerCount;                                   // 3
for (const turn of result.turns) {
  turn.speaker;                                        // 0, 1, 2: numbered in order of first appearance
  turn.start;                                          // 12.4, seconds from the start
  turn.end;                                            // 15.9
}
who.dispose();
```

`diarize` takes the bytes of an audio file (`File`, `Blob`, `ArrayBuffer`, `Uint8Array`), mono `Float32Array` samples at 16 kHz, or `{ samples, sampleRate }` at any rate. In the browser a file is decoded with Web Audio, so any format the browser plays works; in Node the portable decoder reads WAV, so decode other formats first. The browser build runs the graphs on the CPU through WebAssembly; pass `accelerator: "auto"` to `Who.load` to try WebGPU. `result.keepingSpeakers({ minimumShare: 0.05 })` drops the speakers under a share of the recording, as on the other platforms. Create one `Who` and reuse it; `Who.load` downloads the 8-bit build, 32 MB, on first use.

### Long recordings

A recording of up to five minutes is read in one pass, because the part of the model that decides who the speakers are sees it whole. A longer recording is cut into five-minute pieces, each read in one pass, and the speakers are joined across the pieces by voice: a speaker-verification network gives each lane a voice from the moments it speaks alone, and the lanes of the whole recording are clustered at once, so the numbering holds from the first minute to the last. There is no length limit, and a recording that fits one pass is the model at its most accurate.

### Linux and Windows

The same package and the same calls. Add the package as on Apple platforms, add the `Who` product, and write the code above unchanged:

```swift
import Who

let who = Who()                                        // downloads the 8-bit build on first use
let result = try await who.diarize(contentsOf: url)    // or diarize(samples:sampleRate:)
```

What differs underneath: the model runs through LiteRT on the CPU, and the download is the 8-bit build, 32 MB, the one precision published for these platforms. `Who(variant: .fp16)` is an error here rather than a silent switch, since there is no float16 build to load. The turns match the Apple platforms' within the arithmetic of the runtimes.

Threads: LiteRT takes half the machine's logical cores, at most eight; set `DAL_LITERT_THREADS` to choose.


### Choosing a precision

Two precisions are published. Both compute at float16 on the Neural Engine and run at the same speed; `.int8` stores its weights as 8-bit integers and halves the download, at a cost of about half a point of diarization error and with no saving in memory, since the Engine decompresses the weights at load. `.fp16` is the default and the one to ship unless the download size decides.

```swift
let who = Who(variant: .int8)                          // about half the download
```

`.fp16` is the default.

### Downloading ahead of time

```swift
let who = Who()
if !who.isDownloaded() {
    try await who.download { fraction in print("\(Int(fraction * 100))%") }
}
```

`Who(directory:)` points the SDK at a directory you manage. If it already holds the model files the SDK uses them offline; otherwise it downloads them there.

### What comes back

`Diarization.turns` is sorted by start time. Turns of different speakers can overlap, because people do; a turn is one stretch of one speaker's speech, split where that speaker pauses for longer than a frame. `speakerCount` is the number of distinct speakers heard. Speakers are numbered from zero in the order they are first heard, so the labels mean the same thing from one run to the next on the same recording, and nothing else: the model does not know who the people are.

## Files

Each folder holds the model for one runtime, plus its own copy of the four supporting files.

| Directory | Runtime | Weights | Size |
|---|---|---|---:|
| `coreml-fp16/` | Core ML, compiled | float16 | 81MB |
| `coreml-int8/` | Core ML, compiled | 8-bit | 42MB |
| `litert-int8/` | LiteRT | 8-bit | 32MB |
| `onnx-int8/` | ONNX Runtime | 8-bit matrix products, the rest float32 | 99MB |

The Core ML and ONNX folders hold five graphs each. The LiteRT folder holds the same five as signatures of one file, `who.tflite`.

| File | Contents |
|---|---|
| `encoder_6000` | From 60s of audio to voice frames |
| `queries_6000` | The speakers in those 60s and when each one speaks |
| `encoder_30000` | From 300s of audio to voice frames |
| `queries_30000` | The speakers in those 300s and when each one speaks |
| `voice_3256` | A voice print of a 30s stretch, used to match speakers across sections |
| `who_meta.json` | The front end's geometry, each graph's input and output names, the decision thresholds |
| `who_mel_banks.f32` | The mel filterbank the encoders read, 80 by 257, little-endian |
| `who_voice_banks.f32` | The mel filterbank the voice graph reads |
| `who_embed.f16` | The voice graph's last layer, as a table |

## Inputs and outputs

- **In:** 16kHz mono audio of any length, from a few seconds up. The SDK converts other sample rates for you.
- **Out:** each speaker, numbered in the order they first speak, and when they start and stop talking. Times are in seconds, to the nearest 10ms. When two people talk at once, both are marked. Who labels up to four speakers in each five-minute section, and more across a whole recording.

## Languages

Who works from the sound of each voice and has no language setting. Every score on this page was measured on English recordings.

## Results

Measured through the SDK on whole recordings.

| Corpus | Samples | Diarization error rate | Missed speech | False alarm | Speaker confusion |
|---|---:|---:|---:|---:|---:|
| AMI meetings, headset mix | 16 | 0.126 | 0.079 | 0.026 | 0.021 |
| VoxConverse, up to 4 speakers | 86 | 0.084 | 0.027 | 0.040 | 0.017 |
| VoxConverse, 2-21 speakers | 232 | 0.175 | 0.026 | 0.073 | 0.076 |
| NOTSOFAR-1 meetings, far-field, up to 4 speakers | 65 | 0.162 | 0.060 | 0.052 | 0.050 |
| NOTSOFAR-1 meetings, far-field, 3-8 speakers | 129 | 0.243 | 0.087 | 0.057 | 0.098 |
| Earnings-21 calls, 2-20 speakers | 44 | 0.277 | 0.059 | 0.055 | 0.163 |
| DiPCo dinner parties, far-field | 10 | 0.411 | 0.207 | 0.064 | 0.140 |
| CHiME-6 dinner parties, far-field | 2 | 0.399 | 0.190 | 0.081 | 0.128 |

On VoxConverse, the error rate rises with the number of speakers in a recording.

| Speakers | Samples | Diarization error rate |
|---|---:|---:|
| 1 to 2 | 46 | 0.077 |
| 3 | 18 | 0.116 |
| 4 | 22 | 0.078 |
| 5 to 8 | 85 | 0.170 |
| 9 or more | 61 | 0.247 |

## Performance

Through the SDK.

| Device | SDK | Workload | Result |
|---|---|---|---:|
| MacBook Pro, M5 Pro, macOS 26.6 | desert-ant-core 4.2.0, coreml | float16 build, 16 meetings, 544 minutes | 953x faster than real time |
| MacBook Pro, M5 Pro, macOS 26.6 | desert-ant-core 4.2.0, coreml | 8-bit build, 16 meetings, 544 minutes | 965x faster than real time |
| MacBook Pro, M5 Pro, macOS 26.6 | desert-ant-core 4.2.0, coreml | float16 build, model loaded | 241MB memory |
| MacBook Pro, M5 Pro, macOS 26.6 | desert-ant-core 4.2.0, coreml | float16 build, an 8-minute recording | 279MB peak memory |
| MacBook Pro, M5 Pro, macOS 26.6 | desert-ant-core 4.2.0, coreml | float16 build, a 34-minute recording | 377MB peak memory |
| MacBook Pro, M5 Pro, macOS 26.6 | desert-ant-core 4.2.0, coreml | float16 build, a 2.65-hour recording | 867MB peak memory |

On CPU alone, the 8-bit LiteRT build runs the same 544 minutes in 89s on the M5 Pro, measured outside the SDK.

## Limitations

- **More than four speakers in five minutes.** Who splits a recording into five-minute sections and can label up to four speakers per section. Who matches voices across sections, so it can identify more than four speakers in a longer recording. On VoxConverse, the error rate is 8% with one or two speakers, versus 17% with five to eight and 25% with nine or more.
- **Far-field recordings.** Who misses more speech when the speakers are far away from the microphone. In group conversations recorded across the room, Who misses 19-21% of the speech, versus 8% in meetings where everyone wears a headset. Who does best on close-miked audio, such as podcasts, interviews and calls. On room recordings, expect stretches of speech with no speaker label.
- **Overlapping speech.** Who misses the most speech when two people talk at once. On AMI meetings, Who misses 8% of all speech, and about 65% of that is overlapping talk. Expect more misses in lively discussions with lots of interruptions.
- **Short stretches of speech.** Who mixes up speakers more often when many people each speak for only a few seconds. On Earnings-21 calls, with up to 20 speakers, Who assigns 16% of the speech to the wrong speaker. Expect more mix-ups on calls with lots of short remarks.
- **Laughter, applause and jingles.** Who can give a laugh, applause or a jingle its own speaker number. To hide these, set the SDK to drop any speaker with less than a chosen share of the recording's speech.
- Who labels speakers as 1, 2, 3 and so on, not by name, and doesn't transcribe. For a transcript labeled by speaker, pair Who with Voz.

## Built on

Open models and tools this work builds on, with their licenses:

- [pyannote-community/speaker-diarization-community-1](https://huggingface.co/pyannote-community/speaker-diarization-community-1), CC BY 4.0

Dataset attributions are in the weights' third-party notices, linked under License.

<!-- model-footer:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

Third-party notices for the weights: [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/who/blob/main/THIRD_PARTY_NOTICES.md).

## Citation

```bibtex
@software{who_2026,
  title  = {Who: On-device speaker labeling: per-person turns with timestamps},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/who},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
<!-- model-footer:end -->
