<!-- model:start -->
# Clear

Studio sound, no cloud bill.

On-device speech enhancement: denoise, dereverb, and loudness-normalize.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Weights** | [v0.3.0](https://huggingface.co/desert-ant-labs/clear) |
| **Demo** | https://desertant.com/models/clear/ |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.1.0")
```

Then add the `Clear` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:clear:3.1.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/clear @litertjs/core   # browser
npm i @desert-ant-labs/clear                  # Node, prebuilt native core
```
<!-- model:end -->

## Usage

### Swift

```swift
import Clear

let clear = Clear()
let result = try await clear.enhance(path: "in.wav", to: "out.wav")
print(result.realtimeFactor, result.measuredLUFS ?? 0)
```

Without a filesystem, enhance in memory and get WAV bytes back:

```swift
let (result, wav) = try await clear.enhance(bytes: recording)
```

The output is mono by default, whatever goes in. The model is mono, so keeping
a stereo pair costs an inference pass per channel, about 1.8x a mono run, so
it is opt-in:

```swift
let stereo = try await clear.enhance(channels: [left, right], sampleRate: 48_000,
                                     options: .init(channelMode: .preserve))
stereo.channels.count                       // 2
stereo.measuredTruePeakDBFS                 // what the master actually peaks at
stereo.phaseTimings.modelPredictSec         // where the time went
```

Mastering is joint, one gain and one limiter envelope across the channels, so
it never moves the stereo image. `Mastering.balanceChannelsLUFS` is the
exception, for a pair whose sides were recorded at different levels.

### Kotlin

```kotlin
import ai.desertant.clear.Clear
import ai.desertant.clear.LoudnessPreset
import ai.desertant.clear.Mastering
import ai.desertant.clear.Options

Clear(context).use { clear ->
    val result = clear.enhance(samples, 48_000.0)            // 48 kHz out
    result.measuredTruePeakDbfs                              // what the master actually peaks at

    val forSpotify = Options(mastering = Mastering.of(LoudnessPreset.SPOTIFY))
    val louder = clear.enhance(samples, 48_000.0, forSpotify)

    // Mono out by default; ask to keep the pair, at an inference pass each.
    val stereo = clear.enhance(listOf(left, right), 48_000.0,
                               Options(channelMode = ChannelMode.PRESERVE))
    stereo.channelCount                                      // 2
}
```

### JavaScript

```ts
import { Clear } from "@desert-ant-labs/clear";       // browser
// import { Clear } from "@desert-ant-labs/clear/native"; // server-side Node

const clear = await Clear.load();
const result = await clear.enhance(samples, 48_000);   // Float32Array in, 48 kHz out
result.measuredTruePeakDBFS;                           // what the master actually peaks at
await clear.enhance(samples, 48_000, { targetLUFS: "spotify" });

// One entry per channel, and ask to keep them: mono is the default.
const stereo = await clear.enhance([left, right], 48_000, { channelMode: "preserve" });
stereo.channelCount;                                   // 2
clear.dispose();
```

### Loading the model

The weights are fetched from the Hub on first use and cached. See
[model downloads and caching](../../README.md#model-downloads-and-caching).

## Sound

Trained to deliver a **rich, present, close-miked podcast sound**.

- **Denoised.**
  HVAC, keyboard clicks, mouse rustle, mic bumps, room hum, laptop
  fans, coffee shop background, all pulled down without chewing
  consonants.
- **Dereverbed.**
  Untreated bedrooms, offices and hotel rooms come out sounding closer
  to a treated studio. The model does not add reverberation of its own.
- **Warm and present.**
  Low-mids brought forward so voice sits comfortably in a mix rather
  than sounding thin or distant.
- **Sibilance-safe.**
  No harsh peaks introduced when cleaning up S / T / F consonants.
- **No pumping or musical-noise artefacts.**
  Trained with a large detail-preservation loss so breaths, plosives
  and vocal texture stay intact.

## Variants

Two variants ship. Their Core ML artifacts share the exact planar
`spec / feat_erb / feat_spec → spec_enhanced` I/O contract and use a fixed
batch of four independent two-second chunks. The ONNX artifacts retain their
original DFN3 layout.

### clear-studio

The default. Quiet, studio-like character; silences sit close to true
zero.

Best for solo podcasts, tutorials, voiceover, video demos, screen
recordings, and anything that wants a clean broadcast feel.

| File | Purpose | Size |
|---|---|---:|
| `clear-studio.mlmodelc` | ANE-optimized Core ML (fp16 compute + 6-bit weight palette, iOS 16 target) | 9.0 MB |
| `clear-studio.mlmodelc.zip` | Same compiled model, zipped | 8.6 MB |
| `clear-studio.onnx` | Android / cross-platform ONNX (fp16 weights, fp32 I/O) | 24 MB |
| `clear-studio.pt` | PyTorch checkpoint, for research and re-export | 46 MB |

### clear-natural

Preserves room tone, breath, and lip texture.

For treated podcast studios, intentional voiceover, interviews where
the room is part of the take, and remote guest recordings where
absolute silence would sound wrong.

| File | Purpose | Size |
|---|---|---:|
| `clear-natural.mlmodelc` | ANE-optimized Core ML (fp16 compute + 6-bit weight palette, iOS 16 target) | 9.0 MB |
| `clear-natural.mlmodelc.zip` | Same compiled model, zipped | 8.6 MB |
| `clear-natural.onnx` | Android / cross-platform ONNX | 24 MB |
| `clear-natural.pt` | PyTorch checkpoint | 46 MB |

## Performance

The Core ML variants are optimized for the Apple Neural Engine.
`MLComputePlan` confirms that all 492 model operations run on ANE.

`clear-studio`, whole SDK pipeline on a 60-second clip, best of three:

| Device | Realtime factor |
|---|---:|
| iPhone 16 Pro | **302x** |
| MacBook Pro (M5) | **345x** |

On iPhone 16 Pro, first-ever model loading takes approximately 3.4 seconds
while Core ML compiles the ANE program. Cached launches load in approximately
62 ms; applications should warm the model in the background.

## Deployment target

- **Core ML model**: iOS/iPadOS 16.0+ model format; ANE placement depends on hardware and OS.
- **Swift SDK**: iOS 18+, macOS 15+, tvOS 18+, visionOS 2+.
- **Android**: API 24+ (arm64-v8a, x86_64), via LiteRT.
- **Other platforms**: the `.tflite` runs wherever LiteRT does: Linux, Windows, and the browser through LiteRT.js. The ONNX files are kept for runtimes the SDK does not cover.

## What it's good for

- **Meeting recorders.** Zoom, Teams, Meet, Detail exports, single or multi-speaker.
- **Bluetooth microphones.** AirPods, Sony, headset mics.
- **Mobile devices.** iPhone and Android built-in microphone recordings, voice notes, field recordings.
- **Laptop built-in microphones.** MacBook and PC built-in mics.
- **Untreated rooms.** Bedrooms, hotel rooms, kitchens, coffee shops.

Whenever the pitch is *messy recording in, clean audio out*.

## What it is not

- Not a general-purpose audio denoiser.
  Speech is the target; music, effects, and non-vocal signals get pulled down as noise.
- Not a source separator.
  Overlapping speakers stay overlapping.
- Not a voice changer, cloner, or transcription model.

## Keywords

speech enhancement · noise suppression · dereverberation · speech
denoising · reduce noise · clean up audio · normalize volume · turn a
recording into studio sound · messy recording in clean audio out ·
podcast audio · voice cleanup · meeting recorder cleanup · bluetooth
microphone cleanup · mobile device audio · built-in microphone ·
on-device audio · edge ML · Core ML · ONNX · iOS speech enhancement ·
Android speech enhancement · real-time speech enhancement · DFN3 ·
DeepFilterNet · studio sound · podcast sound · TCN · distilled model ·
Apple Neural Engine · ANE
