# Desert Ant Core

![Swift](https://img.shields.io/badge/Swift-iOS%20%7C%20macOS%20%7C%20Linux-F05138?logo=swift&logoColor=white)
![Kotlin](https://img.shields.io/badge/Kotlin-Android-7F52FF?logo=kotlin&logoColor=white)
![TypeScript](https://img.shields.io/badge/TypeScript-Node%20%7C%20Browser%20%7C%20WASM-3178C6?logo=typescript&logoColor=white)

On-device AI SDKs for Swift, Kotlin, and JavaScript. Small, focused models that
run directly on the user's phone, Mac, or browser tab, through Core ML on Apple,
LiteRT (formerly TensorFlow Lite) on Android, and WebAssembly with LiteRT.js on
the web, so text, audio, and images never leave the device.

```swift
import Emo
import Redact

let suggestions = try await Emo().suggestions(for: "Pay my bills")   // 💰 💳 🧾
let clean = try await Redact().redaction(of: "Email Anna at anna@example.hu.")
// Email [GIVEN_NAME_1] at [EMAIL_1].
```

- [Models](#models)
- [Swift](#swift)
- [Android](#android)
- [JavaScript and TypeScript](#javascript-and-typescript)
- [Model downloads and caching](#model-downloads-and-caching)
  - [Offline and airgapped](#offline-and-airgapped)
  - [AWS Lambda on arm64](#aws-lambda-on-arm64)
- [Platform support](#platform-support)
- [Contributing](#contributing)
- [License](#license)

## Models

<!-- models:start -->
| Model | What it does | Platform | Docs |
| --- | --- | --- | --- |
| **Align** | Word-timestamp refinement for Apple's SpeechAnalyzer pipeline. | Apple | [SDK](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/align.md) [Model](https://huggingface.co/desert-ant-labs/align) |
| **Clear** | On-device speech enhancement: denoise, dereverb, and loudness-normalize. | Apple · Android · Linux · Windows · Web · Node | [SDK](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/clear.md) [Model](https://huggingface.co/desert-ant-labs/clear) |
| **Clips** | Short clips and highlights from talking video and audio: podcasts, interviews, meetings. On-device. | Apple · Linux · Windows | [SDK](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/clips.md) [Model](https://huggingface.co/desert-ant-labs/clips) |
| **Ear** | On-device spoken language identification across 99 languages. | Apple · Android · Linux · Windows · Web · Node | [SDK](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/ear.md) [Model](https://huggingface.co/desert-ant-labs/ear) |
| **Emo** | Multilingual on-device emoji suggestion. | Apple · Android · Linux · Windows · Web · Node | [SDK](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/emo.md) [Model](https://huggingface.co/desert-ant-labs/emo) |
| **Gist** | Multilingual on-device content topic tagging across a 36-topic taxonomy. | Apple · Android · Linux · Windows · Web · Node | [SDK](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/gist.md) [Model](https://huggingface.co/desert-ant-labs/gist) |
| **Redact** | Multilingual on-device PII detection and redaction. | Apple · Android · Linux · Windows · Web · Node | [SDK](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/redact.md) [Model](https://huggingface.co/desert-ant-labs/redact) |
| **Shapes** | On-device single-stroke shape recognition. | Apple · Android · Linux · Windows · Web · Node | [SDK](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/shapes.md) [Model](https://huggingface.co/desert-ant-labs/shapes) |
| **Title** | On-device titles and descriptions: a short factual title and a one- to two-sentence description for any passage of text. | Apple | [SDK](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/title.md) [Model](https://huggingface.co/desert-ant-labs/title) |
| **Tongue** | On-device language identification for short text across 84 languages. | Apple · Android · Linux · Windows · Web · Node | [SDK](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/tongue.md) [Model](https://huggingface.co/desert-ant-labs/tongue) |
| **Uhm** | On-device filler-word detection: frame-precise "uh"/"um"/"hmm" spans. | Apple | [SDK](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/uhm.md) [Model](https://huggingface.co/desert-ant-labs/uhm) |
| **Voz** | On-device speech recognition: transcripts with word-level timestamps, 25 languages. | Apple | [SDK](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/voz.md) [Model](https://huggingface.co/desert-ant-labs/voz) |

### In closed beta

Weights exist and the models work, but no SDK ships them yet, so there is
nothing to install today. Ask us if you want early access.

| Model | What it does | Docs |
| --- | --- | --- |
| **Eye** | On-device frame scoring: which shot to keep from a burst or a clip. | [Model](https://huggingface.co/desert-ant-labs/eye) |
| **Face** | On-device face matching across a photo library or through a video. | [Model](https://huggingface.co/desert-ant-labs/face) |
| **Moderator** | On-device NSFW image detection, trained only on licensed and synthetic data. | [Model](https://huggingface.co/desert-ant-labs/moderator) |
| **Schemer** | On-device structured extraction into a caller-supplied JSON schema. | [Model](https://huggingface.co/desert-ant-labs/schemer) |
| **Toxic** | On-device hate-speech triage for European languages. | [Model](https://huggingface.co/desert-ant-labs/toxic) |
| **Who** | On-device speaker labeling: per-person turns with timestamps. | [Model](https://huggingface.co/desert-ant-labs/who) |
<!-- models:end -->

Each model behaves the same on every platform, so you can build a feature once
and ship it everywhere. New models are added regularly, and the weights live on
[Hugging Face](https://huggingface.co/desert-ant-labs).

**Every model's own page is where its examples are**, one page per model in
[`docs/models/`](docs/models/), covering install and usage on every platform it
supports. The rest of this file is what they have in common: platform
requirements, and how model files are downloaded and cached.

## Swift

Requirements: iOS 18+, macOS 15+, tvOS 18+, visionOS 2+, and Swift 6.2+ (Xcode 26).
The floor is the Core ML models', not the code's: they are built for this
deployment target, and an older OS refuses to load them.

Add the package with Swift Package Manager:

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.1.0")
```

Then add a product per model you want, named as in the table above. You only pay
for what you add, so an Emo-only app carries nothing from the other models.
Each model's page has the exact product and an example.

## Android

Requirements: Android API 24+, arm64-v8a and x86_64. Adding a second model does
not double the size it adds to your app.

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

// build.gradle.kts
dependencies {
    implementation("ai.desertant:emo:3.1.0")
    implementation("ai.desertant:redact:3.1.0")
    implementation("ai.desertant:clear:3.1.0")
    implementation("ai.desertant:tongue:3.1.0")
}
```

One dependency per model, using the coordinates from the table above. Tongue is
a plain jar rather than an AAR, a pure Kotlin port with no native libraries, so
it also runs on a bare JVM (17+).

## JavaScript and TypeScript

Each model is its own package, so install the ones you use:

```bash
# Browser (WebAssembly + LiteRT.js):
npm i @desert-ant-labs/emo @litertjs/core

# Server-side inference in Node (prebuilt native core, no extra install):
npm i @desert-ant-labs/emo

# Tongue is pure JavaScript, no wasm, no LiteRT.js, no native core:
npm i @desert-ant-labs/tongue
```

The default import is the browser build. It has no native dependencies, so it
bundles cleanly for every target of a multi-target bundler such as Next.js,
Remix, SvelteKit, or Nuxt, including the server-side rendering pass those
frameworks run in Node. For inference in plain Node, import the `/native`
subpath, which ships prebuilt for linux-x64, linux-arm64, and darwin-arm64.

## Model downloads and caching

Weights are published on the [Hugging Face
Hub](https://huggingface.co/desert-ant-labs). Each SDK version is pinned to one
model revision, so a model never changes under you, and every download is
verified before it is used. (Tongue is the exception: its 2 MB model ships
inside each package, so nothing here applies to it and nothing downloads.)

- **Managed cache**, the default. Files land in the platform cache directory and
  are reused across launches.
- **Your own directory.** Pass `directory` and it becomes the model home. Files
  already there are adopted as-is, so an app that ships the model offline simply
  points at the folder it unpacked. Otherwise the model downloads into it.
- **Self-hosted on the web.** Serve the files yourself and pass `modelBaseUrl`.

`isDownloaded()` answers whether a model is usable with no network, and
`download()` fetches it ahead of time with progress.

### Faster downloads on Apple platforms (the `Xet` trait)

Our Hub repos are stored on [Xet](https://huggingface.co/docs/hub/en/xet/index),
Hugging Face's content-addressed backend, which serves a file as deduplicated
chunks fetched in parallel rather than one stream. Swift consumers can opt into
it with a package trait:

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.1.0",
        traits: ["Xet"])
```

Nothing else changes: the same files land in the same cache and are verified the
same way, and anything not Xet-backed (or a CAS that is having a bad day) falls
back to the ordinary HTTPS download. It is opt-in because it pulls
[swift-xet](https://github.com/huggingface/swift-xet) and the NIO stack into the
resolved graph, which no Linux, Android or web build has any use for. Those
platforms, and the Node and Kotlin SDKs, keep the plain download path.

Set `HF_TOKEN` in the environment for a gated or private repo; public models need
no token.

### Offline and airgapped

Model files are ordinary HTTPS downloads, so a directory can be populated from
any machine: neither the SDK nor a container matching the target platform is
needed. Each model's repo, pinned revision, and per-platform file list are
declared in `Sources/<Model>/Catalog.swift` at the tag you build against; Swift
also exposes them as `modelRepo` and `modelRevision`.

Redact at `v0.4.0`, for example. The Hub repo also holds training and tokenizer
sources, which no SDK reads:

| Platform | Files |
|---|---|
| Apple | `redact.mlmodelc/` (`coremldata.bin`, `metadata.json`, `model.mil`, `weights/weight.bin`, `analytics/coremldata.bin`), `redact_tokenizer.bin`, `labels.json` |
| Android, Linux, Windows, web | `redact.tflite`, `redact_tokenizer.bin`, `labels.json` |

```bash
base=https://huggingface.co/desert-ant-labs/redact/resolve/v0.4.0
for f in redact.tflite redact_tokenizer.bin labels.json; do
  curl -fsSL --create-dirs -o "model/$f" "$base/$f"
done
```

Pass that folder as `directory` and it is adopted as-is, with nothing downloaded
and no network at run time. For a build that has to be reproducible, use the
commit sha in place of the tag - the Hub accepts either, and `v0.4.0` is
`1d65950bbf0459a4d7a94afb85095877f585d99c`. A revision is pinned per SDK version
and moves only with a deliberate bump: every 1.0.x release ships `v0.4.0`.

### AWS Lambda on arm64

Lambda does not mount `/sys/devices/system/cpu`. On arm64 the CPU backend reads
it to enumerate cores, so without it inference fails on every call even though
the library loads. Preload the shim shipped alongside the native:

```
LD_PRELOAD=/var/task/node_modules/@desert-ant-labs/redact/native/linux-arm64/libdalcpushim.so
```

Set it as a function environment variable, and correct the path if the package
lives in a layer (`/opt/nodejs/node_modules/...`). It answers those two sysfs
reads and passes everything else through untouched. The dynamic linker has to
insert it before libc, which is why the SDK cannot do this for you.

x86_64 needs none of this: there the core count comes from a CPU instruction
rather than sysfs.

## Platform support

| Platform | Runtime | Requirements |
|---|---|---|
| iOS, macOS, tvOS, visionOS | Core ML | iOS 18+, macOS 15+, tvOS 18+, visionOS 2+, Swift 6.2+ |
| Android | LiteRT | API 24+, arm64-v8a and x86_64 |
| Browser | WebAssembly + LiteRT.js | any browser with WebAssembly; `@litertjs/core` |
| Node | prebuilt native core | linux-x64, linux-arm64, darwin-arm64 |

## Contributing

Every build, test, and release step is a mise task, so `mise run test` and
`mise run build` do locally what CI does. See
[docs/development.md](docs/development.md).

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0).
Free for most apps; a commercial license is required at scale. Full terms are at
the link. Licensing: <licensing@desertant.com>.
