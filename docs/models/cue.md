<!-- model:start -->
# Cue

Know when someone is talking.

On-device voice activity detection: frame-precise speech spans, any language.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS |
| **Weights** | [v0.1.0](https://huggingface.co/desert-ant-labs/cue) |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.1.0")
```

Then add the `Cue` product to your target.
<!-- model:end -->

## Usage

`Cue` finds the parts of a recording that contain speech. Create one and reuse
it; the model downloads on first use and is cached.

```swift
import Cue

let cue = try await Cue()
let result = try await cue.detect(url)

for span in result.speech {
    print(span.start, span.end)   // seconds
}

result.speechRatio              // how much of the recording is speech
result.containsSpeech           // whether any is
result.realtimeFactor           // seconds of audio per second of wall clock
```

### Downloading

The model is 339 KiB, so the download is quick, but it still needs to happen
once. Fetch it during onboarding to keep it off the first detection, which also
pays a one-time Neural Engine specialization on the load after it.

```swift
if !Cue.isDownloaded() {
    try await Cue.download { print($0.fractionCompleted) }
}
```

Pass `directory:` to adopt files you manage yourself:

```swift
let cue = try Cue(modelDirectory: URL(fileURLWithPath: "/path/to/model"))
```

### Trimming and splitting

`silence()` is the complement of `speech`, so cutting dead air is a subtraction
rather than a second pass.

```swift
let result = try await cue.detect(url)
let keep = result.speech        // ranges to keep
let drop = result.silence()     // ranges to cut
```

Long spans are split at their quietest frame, so a caller slicing audio never
gets an unbounded chunk. `maxSpeechDuration` sets the ceiling (20 s by default).

### Tuning

Defaults match the upstream model's, and every published number was measured at
`.balanced`.

```swift
var options = Cue.Options()
options.bias = .precision       // fewer false alarms on noise and music
options.minSilenceDuration = 0.5  // do not break a sentence at every comma
options.padding = 0.1           // keep 100 ms of air around each span

let result = try await cue.detect(url, options: options)
```


| Option | Default | What it does |
| --- | --- | --- |
| `bias` | `.balanced` | Threshold preset: `.precision` 0.6, `.balanced` 0.4, `.recall` 0.25 |
| `speechThreshold` | `nil` | Overrides the preset |
| `minSpeechDuration` | 0.2 s | Speech shorter than this is not reported |
| `minSilenceDuration` | 0.2 s | A shorter pause does not end a span |
| `maxSpeechDuration` | 20 s | Longer spans are split at their quietest frame |
| `padding` | 0 | Widens every span at both ends, coalescing any that touch |

### Raw probabilities

`probabilities` is one speech probability every 10 ms, for drawing a meter or
applying your own thresholding.

```swift
let result = try await cue.detect(url)
for (i, p) in result.probabilities.enumerated() {
    let t = Double(i) * result.frameDuration
    print(t, p)
}
```

### Other inputs

```swift
try cue.detect(samples: floats)                       // mono, 16 kHz, -1...1
try cue.detect(samples: floats, sampleRate: 44100)    // resampled for you
try await cue.detect(path: "recording.m4a")           // anything AudioIO decodes
```

## Notes

It keys on acoustics rather than words, so it is language-independent; it was
evaluated across 14 languages. Music and singing usually read as speech, which
is what most callers segmenting a recording want. Telling them apart needs an
audio-event model, not this one.

The detector uses 1.6 s of lookahead, so it is for recorded audio rather than
live monitoring. Long inputs are processed in overlapping windows with enough
real context on each side that the result is identical to running the whole
recording at once.
