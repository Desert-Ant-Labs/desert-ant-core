# Desert Ant Core

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
  - [Install](#install)
  - [Usage](#usage)
- [Android](#android)
  - [Install](#install-1)
  - [Usage](#usage-1)
- [JavaScript and TypeScript](#javascript-and-typescript)
  - [Install](#install-2)
  - [Usage](#usage-2)
- [Model downloads and caching](#model-downloads-and-caching)
  - [Offline and airgapped](#offline-and-airgapped)
  - [AWS Lambda on arm64](#aws-lambda-on-arm64)
- [Platform support](#platform-support)
- [Contributing](#contributing)
- [License](#license)

## Models

| Model | What it does | Swift | Android | Web and Node | Weights |
|---|---|---|---|---|---|
| **Emo** | Multilingual emoji suggestion from short text, 23 languages | `Emo` | `ai.desertant:emo` | `@desert-ant-labs/emo` | [Hugging Face](https://huggingface.co/desert-ant-labs/emo) |
| **Redact** | PII detection and reversible redaction, 27 languages | `Redact` | `ai.desertant:redact` | `@desert-ant-labs/redact` | [Hugging Face](https://huggingface.co/desert-ant-labs/redact) |
| **Clear** | Speech enhancement: denoise, dereverb, podcast-ready 48 kHz | `Clear` | `ai.desertant:clear` | `@desert-ant-labs/clear` | [Hugging Face](https://huggingface.co/desert-ant-labs/clear) |
| **Gist** | Content topic tagging over a 36-topic taxonomy, 101 languages | `Gist` | `ai.desertant:gist` | `@desert-ant-labs/gist` | [Hugging Face](https://huggingface.co/desert-ant-labs/gist) |
| **Align** | Word-timestamp refinement for Apple's `SpeechAnalyzer` pipeline, 9 languages | `Align` | Apple-only | Apple-only | [Hugging Face](https://huggingface.co/desert-ant-labs/align) |
| **Tongue** | Language identification for short text, 84 languages | `Tongue` | `ai.desertant:tongue` | `@desert-ant-labs/tongue` | Bundled (2 MB) |

Each model behaves the same on every platform, so you can build a feature once
and ship it everywhere. New models are added regularly; the current set is always
this table, and the weights live on [Hugging
Face](https://huggingface.co/desert-ant-labs).

## Swift

### Install

Requirements: iOS 18+, macOS 15+, tvOS 18+, visionOS 2+, and Swift 6.2+ (Xcode 26).
The floor is the Core ML models', not the code's: they are built for this
deployment target, and an older OS refuses to load them.

Add the package with Swift Package Manager:

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.0.0")
```

Then add a product per model you want, named as in the table above. You only pay
for what you add, so an Emo-only app carries nothing from the other models.

### Usage

Create one instance and reuse it. Construction is cheap and non-blocking; the
model loads on first use, or earlier if you call `download`.

**Emo**

```swift
import Emo

let emo = Emo()
let suggestions = try await emo.suggestions(for: "Pay my bills")
// [EmoSuggestion(emoji: "💰", confidence: ...), ...]

let toned = try await emo.suggestions(for: "go for a run", limit: 1, skinTone: .medium)
// 🏃🏽
```

**Redact**

Redaction is reversible. Mask personal data before sending text to an LLM, then
restore the originals in the reply, on device.

```swift
import Redact

let redact = Redact()
let result = try await redact.redaction(of: "Email Anna Kovács at anna@example.hu.")

print(result.redactedText)
// Email [GIVEN_NAME_1] [SURNAME_1] at [EMAIL_1].

for item in result.items {
    print(item.label.displayName, item.original, item.placeholder, item.confidence)
}

let reply = try await myLLM.rewrite(result.redactedText)
let restored = result.restore(reply)
```

Filter by category, or raise the confidence floor:

```swift
let options = Options(minimumConfidence: 0.7, labels: [.email, .phone, .creditCard])
let contactOnly = try await redact.redaction(of: text, options: options)
```

**Clear**

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
a stereo pair costs an inference pass per channel - about 1.8x a mono run - so
it is opt-in:

```swift
let stereo = try await clear.enhance(channels: [left, right], sampleRate: 48_000,
                                     options: .init(channelMode: .preserve))
stereo.channels.count                       // 2
stereo.measuredTruePeakDBFS                 // what the master actually peaks at
stereo.phaseTimings.modelPredictSec         // where the time went
```

Mastering is joint - one gain and one limiter envelope across the channels - so
it never moves the stereo image. `Mastering.balanceChannelsLUFS` is the
exception, for a pair whose sides were recorded at different levels.

**Tongue**

Nothing to download and nothing async: the 2 MB model ships inside the package,
and a detection is pure arithmetic.

```swift
import Tongue

let tongue = try Tongue()                      // loads the bundled 2 MB model
let detection = tongue.detect("kann ich das haben")

detection.language          // "de"
detection.reliability       // .confident
detection.candidates        // [Prediction(language: "de", probability: 0.999…), …]
detection.isTooCloseToCall  // false
```

**Download ahead of time**

Any model can be fetched before first use, for example during onboarding:

```swift
let emo = Emo()
if !emo.isDownloaded() {
    try await emo.download { fraction in
        print("\(Int(fraction * 100))%")
    }
}
```

**Ship the model with your app**

Point a model at a directory you populated and it is used as-is, offline, with
nothing downloaded:

```swift
let emo = Emo(directory: myModelDirectory)
```

## Android

### Install

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
    implementation("ai.desertant:emo:3.0.0")
    implementation("ai.desertant:redact:3.0.0")
    implementation("ai.desertant:clear:3.0.0")
    implementation("ai.desertant:tongue:3.0.0")
}
```

One dependency per model, using the coordinates from the table above. Tongue is
a plain jar rather than an AAR — a pure Kotlin port with no native libraries —
so it also runs on a bare JVM (17+).

### Usage

`suggestions`, `redaction`, `enhance`, and `download` are suspending functions. A
model owns native resources, so close it when you are done, or let `use { }` do it.

```kotlin
import ai.desertant.emo.Emo
import ai.desertant.emo.EmojiSkinTone

Emo(context).use { emo ->
    val suggestions = emo.suggestions("Pay my bills")               // List<EmoSuggestion>
    val toned = emo.suggestions("go for a run", limit = 1, skinTone = EmojiSkinTone.MEDIUM)
}
```

```kotlin
import ai.desertant.redact.Redact

Redact(context).use { redact ->
    val result = redact.redaction("Email Anna Kovács at anna@example.hu.")
    println(result.redactedText)                 // Email [GIVEN_NAME_1] [SURNAME_1] at [EMAIL_1].
    val restored = result.restore(llmReply)
}
```

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

```kotlin
import ai.desertant.tongue.Tongue

// Android: pass the Context. On a bare JVM call Tongue.bundled().
val tongue = Tongue.bundled(context)
val detection = tongue.detect("kann ich das haben")
detection.language                               // "de"
detection.isTooCloseToCall                       // false
```

Download before first use, or point at your own directory:

```kotlin
val emo = Emo(context)
if (!emo.isDownloaded()) emo.download()

val offline = Emo(context, directory = myModelDir)   // adopted as-is, nothing downloaded
```

## JavaScript and TypeScript

### Install

Each model is its own package, so install the ones you use:

```bash
# Browser (WebAssembly + LiteRT.js):
npm i @desert-ant-labs/emo @litertjs/core

# Server-side inference in Node (prebuilt native core, no extra install):
npm i @desert-ant-labs/emo

# Tongue is pure JavaScript — no wasm, no LiteRT.js, no native core:
npm i @desert-ant-labs/tongue
```

The default import is the browser build. It has no native dependencies, so it
bundles cleanly for every target of a multi-target bundler such as Next.js,
Remix, SvelteKit, or Nuxt, including the server-side rendering pass those
frameworks run in Node. For inference in plain Node, import the `/native`
subpath, which ships prebuilt for linux-x64, linux-arm64, and darwin-arm64.

### Usage

```ts
import { Emo } from "@desert-ant-labs/emo";           // browser
// import { Emo } from "@desert-ant-labs/emo/native"; // server-side Node

const emo = await Emo.load();                                // downloads and caches on first use
const suggestions = await emo.suggestions("Pay my bills");   // [{ emoji, confidence }, ...]
emo.dispose();
```

```ts
import { Redact } from "@desert-ant-labs/redact";

const redact = await Redact.load();
const result = await redact.redaction("Email Anna Kovács at anna@example.hu.");
console.log(result.redactedText);   // Email [GIVEN_NAME_1] [SURNAME_1] at [EMAIL_1].
const restored = result.restore(llmReply);
redact.dispose();
```

```ts
import { Clear } from "@desert-ant-labs/clear";

const clear = await Clear.load();
const result = await clear.enhance(samples, 48_000);   // Float32Array in, 48 kHz out
result.measuredTruePeakDBFS;                           // what the master actually peaks at
await clear.enhance(samples, 48_000, { targetLUFS: "spotify" });

// One entry per channel, and ask to keep them: mono is the default.
const stereo = await clear.enhance([left, right], 48_000, { channelMode: "preserve" });
stereo.channelCount;                                   // 2
clear.dispose();
```

```ts
import { Tongue } from "@desert-ant-labs/tongue";      // one import everywhere

const tongue = await Tongue.load();                    // Node: reads the bundled model
const detection = tongue.detect("kann ich das haben");
detection.language;                                    // "de"
detection.isTooCloseToCall;                            // false
```

In a browser, serve tongue's two model files yourself (a bundler does not serve
files out of `node_modules`) and pass `from`; both files are exported subpaths,
so a copy script can `require.resolve` them under pnpm and Yarn PnP too:

```ts
const tongue = await Tongue.load({ from: "/models/tongue" });
```

Self-host the model files or track download progress:

```ts
const emo = await Emo.load({
  modelBaseUrl: "/assets/emo/",                        // browser: serve the files yourself
  directory: "/var/cache/emo",                         // Node: adopt or download here
  onProgress: (fraction) => console.log(fraction),
});
```

Bring your own LiteRT.js module, useful for custom bundler setups:

```ts
import * as litert from "@litertjs/core";

const emo = await Emo.load({ litert, litertWasmDir: "/path/to/@litertjs/core/wasm/" });
```

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
