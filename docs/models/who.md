<!-- model:start -->
# Who

Label who said what in audio and video.

On-device speaker labeling: per-person turns with timestamps.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Weights** | [v0.3.4](https://huggingface.co/desert-ant-labs/who) |
| **Demo** | https://desertant.com/models/who/ |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.2.0")
```

Then add the `Who` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:who:4.2.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/who @litertjs/core   # browser
npm i @desert-ant-labs/who                  # Node, prebuilt native core
```
<!-- model:end -->

## Usage

Who labels the speakers of a recording and gives each one's turns with timestamps: who spoke when, in one pass over the audio, with no clustering and nothing leaving the device. It is built for conversations of up to four speakers, the podcasts, interviews and meetings an app records; a recording with more voices is labelled with its four most present ones. A one-hour recording takes about two seconds on the Neural Engine.

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

The same package and the same calls. Add the package as on Apple platforms ([requirements](../../README.md#platform-support)), add the `Who` product, and write the code above unchanged:

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
