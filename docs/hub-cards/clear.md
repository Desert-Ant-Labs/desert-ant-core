---
license: other
license_name: desert-ant-labs-source-available-1.0
license_link: https://license.desertant.com/1.0
language:
- en
tags:
- audio
- speech
- speech-enhancement
- speech-denoising
- noise-suppression
- dereverberation
- podcast
- on-device
- coreml
- onnx
- ios
- android
- deepfilternet
pipeline_tag: audio-to-audio
---

# Clear

On-device speech enhancement for podcasters, video creators and voice apps.

**Messy recording in, clean audio out.** Reduce noise, clean up audio,
normalize volume. Takes noisy 48 kHz mono or stereo audio (meeting
recorders, bluetooth microphones, mobile device built-in mics, a laptop
in a coffee shop) and returns rich, present, podcast-ready sound.

Runs entirely on the Apple Neural Engine via Core ML and on Android via
ONNX Runtime. The Core ML assets use the iOS 16 model format; the Swift SDK
currently supports iOS 17+ and macOS 14+.

## Sound

Trained to deliver a **rich, present, close-miked podcast sound**.

- **Denoised.**
  HVAC, keyboard clicks, mouse rustle, mic bumps, room hum, laptop
  fans, coffee shop background — all pulled down without chewing
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

- **Core ML model** — iOS/iPadOS 16.0+ model format; ANE placement depends on hardware and OS.
- **Swift SDK** — iOS 18+, macOS 15+, tvOS 18+, visionOS 2+.
- **Android** — API 24+ (arm64-v8a, x86_64), via LiteRT.
- **Other platforms** — the `.tflite` runs wherever LiteRT does: Linux, Windows, and the browser through LiteRT.js. The ONNX files are kept for runtimes the SDK does not cover.

## Integration

All three SDKs live in
[`desert-ant-core`](https://github.com/Desert-Ant-Labs/desert-ant-core) and ship
one version together.

- **iOS / macOS.** Swift Package Manager: depend on `desert-ant-core` and take
  its `Clear` product. The model is downloaded on first use and cached.
- **Android / JVM.** `ai.desertant:clear` on Maven Central.
- **JavaScript / TypeScript.**
  [`@desert-ant-labs/clear`](https://www.npmjs.com/package/@desert-ant-labs/clear) —
  WebAssembly + LiteRT.js in the browser, a prebuilt native core in Node.

**Direct low-level use.** Load the `.mlmodelc` with Core ML and feed planar
fp16 tensors: `spec (4,2,481,200)`, `feat_erb (4,1,32,200)`, and
`feat_spec (4,2,96,200)`. Read `spec_enhanced (4,2,481,200)`, then ISTFT
back to the time domain. Batch elements are independent. The ONNX files keep
the original DFN3 layout for cross-platform runtimes. Integrations must handle
STFT, feature extraction, layout conversion, ISTFT, and mastering around the
Core ML call.

See also: [desertant.com/models/clear](https://desertant.com/models/clear/).

## What it's good for

- **Meeting recorders.** Zoom, Teams, Meet, Detail exports — single or multi-speaker.
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
