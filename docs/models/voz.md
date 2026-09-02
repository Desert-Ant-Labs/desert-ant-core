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
