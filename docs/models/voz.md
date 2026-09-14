<!-- model:start -->
# Voz

Transcribe 10 minutes in 2 seconds.

On-device speech recognition: transcripts with word-level timestamps, 25 languages.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS |
| **Languages** | 25 |
| **Weights** | [v0.1.0](https://huggingface.co/desert-ant-labs/voz) |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.1.0")
```

Then add the `Voz` product to your target.
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

## Dictation

`Voz.Live` is the streaming path: push audio as it is captured, get text as it
is spoken. It is a separate entry point from `transcribe`, with its own model
function, because the two want opposite things: a file wants throughput and a
microphone wants the delay between a word and its text to be small.

```swift
import Voz

let live = try await Voz.Live()
await live.prewarm()                    // at launch, once

// on key down
Task {
    for await update in await live.start() {
        field.text = update.text        // the transcript as it stands
    }
}

// from the audio callback, on any thread
live.append(samples)

// on key up
let result = try await live.finish()    // text, words, timings
```

`append` is safe to call from a CoreAudio render callback. It takes an
uncontended lock and returns, and never awaits, so the callback keeps its
deadline. It is also safe to append everything and call `finish()` on the next
line: the audio is committed synchronously, not handed to a task.

### Two passes, and what `stable` promises

Each update carries the **whole** transcript, because it can be revised. Two
graphs read the same audio:

| | answers in | what it sees |
|---|---|---|
| streaming | ~200 ms | a chunk, plus a bounded left context |
| refine | ~1 s | the last 15 s, with full context in both directions |

The streaming pass puts text on screen immediately; the refine pass re-reads
recent speech a moment later and corrects it. `update.stable` is the prefix
that has been through the second pass, been agreed on by two consecutive
passes, and fallen behind the splice window. **It will not be re-edited**, so a
client that wants minimal edits can rewrite only the tail:

```swift
field.replaceText(after: update.stable.count,
                  with: update.text.dropFirst(update.stable.count))
```

That guarantee is structural rather than statistical: settled words are carried
verbatim between passes instead of being recomputed. An earlier version derived
it from a time frontier alone, which is not enough, because an utterance shorter
than the window is re-read from zero every pass and its normalization statistics
change as more audio arrives, so even the first word can come out different.

Set `Options.refine = false` for a single-pass stream. Text then only ever
appends, and accuracy is whatever the streaming graph alone can do.

### Cost

```swift
var options = Voz.Live.Options()
options.refineInterval = 1.5   // how much new audio between passes
options.refineContext  = 15    // how far back each pass re-reads
```

A pass costs about `refineContext / 46` seconds, so those two numbers are the
compute budget. Defaults measured on an M1 at true 1x: **31% duty** during
active speech, 112 MB resident, both passes on the Neural Engine. Dictation is
bursty, so that is a third of one engine for the few seconds a phrase takes.

Raising `refineInterval` is close to free: latency is dominated by how long a
pass takes, not by how often one runs, so 2.5 s cuts duty to 23% and leaves
correction latency where it was.

### Latency

```swift
await live.algorithmicLatency   // the floor, before any compute
await live.chunkDuration        // audio per encoder dispatch
```

Two terms decide the streaming floor: the audio the frontend needs from *after*
a word before it can describe it, and the chunk that word waits out. Both are
fixed when the model is exported, so `algorithmicLatency` is a property of the
bundle rather than of the machine, and `Update.latency` reports what each piece
of text actually cost.

### Warm up before the hotkey, not after

Three separate costs hide behind a first prediction, and `prewarm()` pays all of
them somewhere the user is not waiting:

- Core ML specializes the Neural Engine program on first use.
- Warmup is about three calls: the first is ~3.6x steady, the second ~2.1x.
- The SoC clocks down when it is idle, and a streaming workload is idle most of
  the time by construction. Measured on an M1, the same chunk takes about twice
  as long on an otherwise idle machine as on a busy one.

Call it at launch. `start()` also runs one warm cycle by default, which costs
nothing in wall clock: a chunk needs a few hundred milliseconds of audio before
it can run at all, and a person takes about that long to start talking after
pressing a key.

### Both modes, one download

`encoder.mlmodelc` and `decoder.mlmodelc` are multifunction models whose
`offline` and `realtime` functions share their conformer weights, so dictation
costs about 10 MB on top of the offline bundle rather than a second download.
Loading both functions costs 26 MB of resident memory, not a second copy: Core
ML maps the weights from disk and the two functions share the pages.

Reaching a function needs `MLModelConfiguration.functionName`, which is why
`Voz.Live` requires iOS 18 / macOS 15 where `Voz` requires iOS 17. A bundle
without a realtime function throws on `Voz.Live` construction and leaves
`transcribe` working.

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

- **Apple platforms only.** The runtime drives Core ML directly, because the
  things that make it fast (preallocated buffers, `outputBackings`, a
  lane-batched decode loop) are not expressible through the generic inference
  shape the other models share. There is no Android, Linux or web build.
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
- **`Voz.Live` needs iOS 18 / macOS 15**, and a bundle built with a realtime
  function. `Voz.transcribe` keeps the iOS 17 floor and works with either.
