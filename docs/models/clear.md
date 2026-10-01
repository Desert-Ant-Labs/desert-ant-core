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
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.6.0")
```

Then add the `Clear` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:clear:3.6.0")
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

Clear returns mono audio by default, whatever the input. The model processes one channel at a time. Keeping a stereo pair costs an inference pass per channel, which we measured at 1.8x a mono run. Stereo output is opt-in:

```swift
let stereo = try await clear.enhance(channels: [left, right], sampleRate: 48_000,
                                     options: .init(channelMode: .preserve))
stereo.channels.count                       // 2
stereo.measuredTruePeakDBFS                 // what the master actually peaks at
stereo.phaseTimings.modelPredictSec         // where the time went
```

The SDK masters the channels jointly, with one gain and one limiter envelope across all channels. Mastering keeps the stereo image as recorded. If the two sides were recorded at different levels, set `Mastering.balanceChannelsLUFS` to bring each channel to the same loudness before mastering.

### Kotlin

```kotlin
import ai.desertant.clear.Clear
import ai.desertant.clear.LoudnessPreset
import ai.desertant.clear.Mastering
import ai.desertant.clear.Options

Clear(context).use { clear ->
    val result = clear.enhance(samples, 48_000.0)            // 48kHz output
    result.measuredTruePeakDbfs                              // what the master actually peaks at

    val forSpotify = Options(mastering = Mastering.of(LoudnessPreset.SPOTIFY))
    val louder = clear.enhance(samples, 48_000.0, forSpotify)

    // Mono by default. Keeping the pair costs an inference pass per channel.
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
const result = await clear.enhance(samples, 48_000);   // samples is a Float32Array, output is 48kHz
result.measuredTruePeakDBFS;                           // what the master actually peaks at
await clear.enhance(samples, 48_000, { targetLUFS: "spotify" });

// One entry per channel. Mono is the default, so ask to keep the channels.
const stereo = await clear.enhance([left, right], 48_000, { channelMode: "preserve" });
stereo.channelCount;                                   // 2
clear.dispose();
```

### Loading the model

The SDK downloads the weights from Hugging Face on first use and caches them. See [model downloads and caching](../../README.md#model-downloads-and-caching).

## Sound

Clear delivers a rich, present, close-miked podcast sound.

- Clear pulls down HVAC, keyboard clicks, mouse rustle, mic bumps, room hum, laptop fans and coffee shop background, without chewing consonants.
- Clear removes the reverb of untreated bedrooms, offices and hotel rooms, so they sound closer to a treated studio. Clear doesn't add reverberation of its own.
- Clear brings the low-mids forward, so the voice sits comfortably in a mix and doesn't sound thin or distant.
- Clear introduces no harsh peaks when it cleans up S, T and F consonants.
- Clear adds no pumping or musical-noise artifacts. Breaths, plosives and vocal texture stay intact.

## Variants

Clear is available in two variants. The variants are the same size and run at the same speed, so pick one by the sound you want. Both variants have files for every runtime. Only the Swift SDK can select a variant: `Clear(variant: .clearNatural)`.

### clear-studio

`clear-studio` is the default. `clear-studio` has a quiet, studio-like character. Silences sit close to true zero.

Use `clear-studio` for solo podcasts, tutorials, voiceover, video demos, screen recordings, and anything that needs a clean broadcast sound.

| File | Purpose | Size |
|---|---|---:|
| `clear-studio.mlmodelc` | Core ML for the Apple Neural Engine (iOS 16 model format) | 9.0MB |
| `clear-studio.mlmodelc.zip` | Same compiled model, zipped | 8.6MB |
| `clear-studio.onnx` | Cross-platform ONNX | 24MB |

### clear-natural

`clear-natural` preserves room tone, breath, and lip texture.

Use `clear-natural` for treated podcast studios, intentional voiceover, interviews where the room is part of the take, and remote guest recordings where absolute silence would sound wrong.

| File | Purpose | Size |
|---|---|---:|
| `clear-natural.mlmodelc` | Core ML for the Apple Neural Engine (iOS 16 model format) | 9.0MB |
| `clear-natural.mlmodelc.zip` | Same compiled model, zipped | 8.6MB |
| `clear-natural.onnx` | Cross-platform ONNX | 24MB |

## Performance

On Apple platforms, all 492 operations of the Core ML model run on the Neural Engine, as reported by `MLComputePlan`.

We timed `clear-studio` through the whole SDK pipeline on a 60s clip, on Apple devices, and kept the best of three runs:

| Device | Realtime factor |
|---|---:|
| iPhone 16 Pro | **302x** |
| MacBook Pro (M5) | **345x** |

On iPhone 16 Pro, the first model load takes 3.4s while Core ML compiles the model for the Neural Engine. After that, a load takes 62ms. Warm the model in the background so your users don't wait on the first load. We have no timings for Android, Linux, Windows or the browser.

## Deployment target

- **Core ML model**: iOS/iPadOS 16.0+ model format. Neural Engine placement depends on the hardware and the OS version.
- **Swift SDK**: iOS 18+, macOS 15+, tvOS 18+, visionOS 2+.
- **Android**: API 24+ (arm64-v8a, x86_64), via LiteRT.
- **Other platforms**: the `.tflite` runs wherever LiteRT does: Linux, Windows, and the browser through LiteRT.js. Use the ONNX files to run Clear in a runtime the SDK doesn't cover.

## What Clear is good for

- Meeting recordings from Zoom, Teams, Meet and Detail exports, with one speaker or several.
- Bluetooth microphones: AirPods, Sony, headset mics.
- Recordings on iPhone and Android built-in microphones: voice notes and field recordings.
- Laptop built-in microphones on MacBooks and PCs.
- Untreated rooms: bedrooms, hotel rooms, kitchens, coffee shops.

## What Clear doesn't do

- Clear cleans up speech only. Clear treats music, sound effects, and other non-speech sound as noise and pulls it down.
- Clear doesn't separate sources. Overlapping speakers stay overlapping.
- Clear doesn't change or clone voices. Clear doesn't transcribe speech.

## Keywords

speech enhancement · noise suppression · dereverberation · speech denoising · reduce noise · clean up audio · normalize volume · turn a recording into studio sound · messy recording in clean audio out · podcast audio · voice cleanup · meeting recorder cleanup · bluetooth microphone cleanup · mobile device audio · built-in microphone · on-device audio · edge ML · Core ML · ONNX · iOS speech enhancement · Android speech enhancement · real-time speech enhancement · studio sound · podcast sound · Apple Neural Engine · ANE

## License

Clear is available under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Most apps can use Clear for free. At scale, you need a commercial license. The link has the full terms. For licensing, email <licensing@desertant.com>.
