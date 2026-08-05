# desert-ant-core

[![macOS](https://github.com/Desert-Ant-Labs/desert-ant-core/actions/workflows/macos.yml/badge.svg)](https://github.com/Desert-Ant-Labs/desert-ant-core/actions/workflows/macos.yml)
[![iOS](https://github.com/Desert-Ant-Labs/desert-ant-core/actions/workflows/ios.yml/badge.svg)](https://github.com/Desert-Ant-Labs/desert-ant-core/actions/workflows/ios.yml)
[![Android](https://github.com/Desert-Ant-Labs/desert-ant-core/actions/workflows/android.yml/badge.svg)](https://github.com/Desert-Ant-Labs/desert-ant-core/actions/workflows/android.yml)
[![WASI](https://github.com/Desert-Ant-Labs/desert-ant-core/actions/workflows/wasi.yml/badge.svg)](https://github.com/Desert-Ant-Labs/desert-ant-core/actions/workflows/wasi.yml)

Reusable, cross-platform Swift building blocks shared by Desert Ant Labs'
on-device model SDKs, plus the model catalog itself.

Each model is its own top-level module under `Sources/<Model>/`, all on the same
mechanisms (one catalog declaration, the verified model
store, the platform inference session, and a common ABI shape):

| Model | Product | What it does |
|---|---|---|
| `emo` | `Emo` | multilingual emoji suggestion (text in, ranked emoji out) |
| `redact` | `Redact` | PII detection and redaction (text in, spans out) |
| `clear` | `Clear` | speech enhancement: denoise, dereverb, loudness-normalize (audio in, 48 kHz mono out) |

Adding a model is one registry entry plus its binding and native entry targets.

A model target depends on `DesertAnt` for the shared runtime, then names only
its optional capabilities. For example, Emo needs only `DesertAnt`, while Clear
also depends on `AudioIO` and `AudioDSP`. This keeps audio code out of Emo while
still giving model sources one import for the common APIs.

Each module exposes one small public API and picks a per-platform backend behind
it, so the code that uses it never sees a platform `#if`:

| Module | API | Apple / Linux | Android | WebAssembly |
|---|---|---|---|---|
| `ModelCatalog` | what a model declares (coordinates + per-platform file manifest), what it implements to be callable from another language, and the `LoadedModel` shell an SDK wraps | same on every platform | | |
| `Regex` (type `Pattern`) | stdlib-`Regex`-shaped matching | `NSRegularExpression` | `java.util.regex` (via `CHostBridge`) | JS `RegExp` |
| `JSON` | `Codable` decode + encode | `Foundation.JSONDecoder`/`Encoder` | host JSON parser (via `CHostBridge`) + tree encoder | JS `JSON.parse` + tree encoder |
| `TextNormalization` | `String.nfkc` | Foundation `precomposed...` | platform ICU `unorm2` (`libicu`) | JS `String.normalize` |
| `AudioIO` | decode to mono `Float` + WAV encode | AVFoundation (Apple) / WAV codec (Linux) | host MediaCodec (via `CHostBridge`) | JS `AudioContext.decodeAudioData` |
| `AudioDSP` | STFT/ISTFT, mel, windows, framing | Accelerate BLAS/vDSP | pure Swift | pure Swift |
| `FFIBuffer` | length-prefixed typed C-ABI buffer | same on every platform | | |
| `WasmBindings` | model-agnostic wasm export surface | empty | empty | `globalThis.__DesertAntExports` |
| `HostBridge` | Android JNI harness for model SDKs | empty | JNI marshalling + installs `CHostBridge` | empty |
| `CHostBridge` | generic host-callback C bridge | - | installed by `HostBridge` | - |
| `ModelStore` | SHA-256-verified Hub downloads and `StoredModel` access | URLSession + FileManager | host HTTP + POSIX | JS fetch + node fs / memory |
| `Inference` | named-tensor `InferenceSession` (`Tensor` in/out) | Core ML / `LiteRTSession` | `LiteRTSession` | `JSInferenceSession` (LiteRT.js host) |
| `PlatformSupport` | env access, blocking FFI bridge, `LazyLoader`, async HTTP client | URLSession | host `java.net` (`CHostBridge`) | JS `fetch` |
| `Usage` | usage turnstile: build/send `load` events | POST via HTTP client | POST via HTTP client | POST via HTTP client |

The design deliberately avoids linking Foundation on Android and wasm (it would
add a ~40 MB ICU blob); instead it calls the host platform's own regex/JSON,
which are already loaded. See each module's source header for details.

### SwiftPM model registry

A model is **one folder and one registry line**. `Sources/<Model>/`
holds the API, the payload codec (`Binding.swift`), the exported symbols
(`Native.swift`), and the wasm entry (`Web/main.swift`); the entry in
`Package.swift`'s `models: [ModelPackage]` derives the library, the Android and
Node products, the wasm executable, and the test target from it. Optional
dependencies (Clear names `AudioIO`/`AudioDSP`) and test resources live on that
same entry, so most models need only a name.

The exported symbols are model-scoped (`emo_create`,
`Java_ai_desertant_emo_EmoNative_*`) rather than generic. `@_cdecl` names are
global and SwiftPM links every test target into one binary, so a shared
`dal_create` would collide between two models; scoping it is what lets a model
stay a single target. Everything behind those names is model-agnostic and lives
in `NativeBindings`.

## Regex

```swift
import Regex

let re = try Pattern(#"(\d{4})-(\d{2})"#)    // or `try regex(...)`; `rx("...")` traps, for constants
if let m = text.firstMatch(of: re) {        // reads like the standard library
    text[m.range]        // Range<String.Index>  (whole match)
    m[1].substring       // Substring?           (capture 1)
}
for m in text.matches(of: re) { ... }
re.wholeMatch(in:); re.prefixMatch(in:); re.ignoresCase(); re.contains(in:)
```

The module is `Regex` but the type is `Pattern`: a type named `Regex` would
clash with the standard library's `Regex` and can't be module-qualified. Use
`Pattern(_:)` / `regex(_:)` / `rx(_:)` and the `String` matching methods
(`text.firstMatch(of:)`, `text.matches(of:)`, ...). It does not conform to
`RegexComponent` (that would force the stdlib engine), so regex literals and
generic `RegexComponent` contexts don't accept it.

## JSON

```swift
import JSON

let user = try JSONDecoder().decode(User.self, from: jsonString)   // or from: [UInt8]
let json = try JSONEncoder().encodeToString(user)                  // or encode(_) -> [UInt8]
```

Same shape as `Foundation.JSONDecoder`/`JSONEncoder`. On Apple/Linux it wraps
Foundation's; on Android/wasm it drives standard-library `Codable` over a JSON
tree (host-parsed for decoding, serialized here for encoding — no Foundation, no
hand-rolled grammar). Input is `String`/`[UInt8]` because `Data` is Foundation-
only. Encoded output is compact with object keys sorted, so it is deterministic
and byte-identical on every platform.

## TextNormalization

```swift
import TextNormalization

let normalized = text.nfkc   // Unicode NFKC, using the platform's own normalizer
```

Text models normalize before tokenizing (SentencePiece/XLM-R expect NFKC).
Each platform already ships a normalizer, so this bundles no ICU where the OS or
host provides one: Foundation on Apple/Linux, the host's `java.text.Normalizer`
(delegated through `CHostBridge`, so no `libicu` link and no API 31 floor) on
Android, `String.prototype.normalize` on wasm.

## FFIBuffer

A model core with a C ABI returns results as a self-describing binary payload
instead of JSON, so neither side hand-rolls a parser. `FFIWriter` builds a
big-endian, length-prefixed buffer (`u32`/`u64`/`f64`/length-prefixed UTF-8
strings); the host reads it with its own standard library (see the matching
`FfiReader` in `kotlin/src/main/kotlin/ai/desertant/core/HostBridge.kt`, a thin
`java.nio.ByteBuffer` cursor) and
frees it with `ffiFree`. The payload *schema* is the model's own concern.

## LoadedModel (the SDK shell)

Resolving a model's files, building it once, sharing that single load with every
concurrent caller, and answering "is it available offline?" are the same for
every model, so an SDK does not write them. It wraps a `LoadedModel` and adds
only its public API and how a resolved directory becomes its runtime:

```swift
public final class Emo: @unchecked Sendable {
    private let model: LoadedModel<Model>

    public convenience init(directory: String? = nil) {
        self.init(directory: directory, cacheRoot: nil)
    }

    public init(directory: String?, cacheRoot: String?) {
        model = LoadedModel(EmoModel.self, directory: directory, cacheRoot: cacheRoot) { files in
            try Model(assets: await .emo(files: files))
        }
    }

    public func isDownloaded() -> Bool { model.isDownloaded() }
    public func download(progress: ...) async throws { try await model.download(progress: progress) }
    public func suggestions(...) async throws -> [EmoSuggestion] {
        try await model.value().suggestions(...)
    }
}
```

Construction starts nothing; the first `value()` or `download(progress:)`
resolves the files (adopting `directory`, else downloading into it or into the
managed cache) and builds the runtime. A failed load is not cached, so a later
call retries. `LoadedModel { ... }` wraps a runtime whose inputs the caller
already has (the cross-language bindings and the wasm host's self-hosted files),
with nothing to resolve or download.

## WasmBindings (the wasm ABI)

One export shape for every model, the WebAssembly twin of each model's native
entry points: options in and results out are `FFIBuffer` payloads the model
encodes itself, so adding a model adds no export, no plumbing, and no JS glue.
A model's wasm entry point installs it and says only how the JS host's
self-hosted files become an instance:

```swift
// Sources/<Model>/Web/main.swift, in full
installWasmExports([
    WasmModel(EmoModel.self, binding: EmoBinding.self) { sidecars, session in
        Emo(assets: ModelAssets(metaJSON: ..., tokenizer: ..., session: session))
    },
])
```

That installs, keyed by model id so two SDKs on one page cannot clobber each
other:

```js
globalThis.__DesertAntExports.emo = {
  create(cacheRoot?, directory?), createSelfHosted(files),   // -> handle
  isDownloaded(handle), download(handle, onProgress?),
  run(handle, text, options?, group?, deviceId?),            // -> Uint8Array
  endCallGroup(id), destroy(handle), flushTelemetry(),
}
```

The JS side resolves it with `wasmExports(modelId)` (or gets it back from
`browserSetup`/`nodeSetup`), so a model package supplies only its payload codecs.
`group` and `deviceId` behave exactly as on the C ABI, so usage attribution and
call grouping work identically on every runtime.

## AudioIO and AudioDSP

One decode/encode API and one DSP toolbox, so an audio model SDK (clear, uhm)
ships no per-platform audio code. `AudioIO.decode` always returns mono `Float`
at the sample rate you ask for, resampling and mixing down for you:

```swift
import AudioIO

let samples = try await AudioIO.decode(path: file, sampleRate: 16_000)  // or decode(bytes:)
let wav = AudioIO.encodeWAV(samples, sampleRate: 16_000)                // 16-bit PCM, portable
```

`decode` is `async` (the wasm backend awaits a JS Promise; native backends
satisfy it synchronously) and picks the backend per platform: AVFoundation on
Apple, the pure-Swift WAV codec on Linux, the host decoder through
`CHostBridge`'s `host_audio_decode` on Android, and
`AudioContext.decodeAudioData` via the `__DalAudioHost` JS global on wasm.
Encoding a 16-bit PCM WAV is pure Swift, identical everywhere.

The host decoders ship in core's own runtime artifacts, so a model SDK writes no
audio glue: `HostBridge.audioDecode` (MediaExtractor/MediaCodec) in the
published `ai.desertant:core` Android artifact, wired by `installHostBridge`;
and `installAudioHost()` in the `@desert-ant-labs/core` npm package (Web Audio
in the browser, the WAV codec under Node), which sets `__DalAudioHost`.

`AudioDSP` is the shared spectral/vector toolbox a speech model runs on both
sides of inference. Pure Swift, Accelerate-backed on Apple (STFT/mel run as BLAS
matmuls on the vector units), so every platform gets bit-compatible results:

```swift
import AudioDSP

let stft = STFT(nFFT: 400, hop: 100)          // periodic Hann, center + reflect pad
let spec = stft.forward(samples)              // magnitude()/phase() available
let audio = stft.inverse(spec, length: samples.count)   // windowed COLA overlap-add

let (norm, gain) = VectorOps.energyNormalize(samples)   // undo with scaled(_, by: 1/gain)
let mel = MelSpectrogram(sampleRate: 16_000, nFFT: 400, hop: 160, mels: 80).logMel(samples)

// Run a fixed-size model over an arbitrary-length signal and stitch outputs:
for (start, end) in Framing.windows(count: n, window: 30 * sr, hop: 25 * sr) { /* run */ }
var acc = OverlapAccumulator(length: totalFrames)       // average() or normalized() (COLA)
```

## ModelStore and model resources

`ModelDistribution` lets model packages declare shared files, Apple and portable
artifacts, and optional wasm session configuration without platform branches.
Core selects the artifact, creates the platform store, downloads atomically,
verifies size and SHA-256, and writes a spec-specific manifest for safe offline
reuse. Lower-level `ModelStore.download` returns a `StoredModel`, so packages read
sidecars and obtain runtime artifact paths without selecting a filesystem or
joining platform paths:

```swift
let distribution = ModelDistribution(
    repo: "org/model",
    revision: "v1",
    files: [
        .apple: ["model.mlmodelc/", "apple_tokenizer.bin"],
        .linux: ["model.tflite", "tokenizer.bin", "labels.json"],
    ]
)
let files = try await distribution.install()          // download + cache
// Or bypass download and caching entirely:
let local = try distribution.load(from: "/path/to/model-directory")
let tokenizer = try files.read("tokenizer.bin")
let modelPath = files.path("model.tflite")
```

No model is ever bundled as a package resource: a model is downloaded on demand
to a managed cache location, or to a directory the consumer names. An SDK
consumer "bundles" a model by pointing that directory at a folder that already
holds the files, which is then adopted as-is and used offline. On wasm,
`StoredModel.initializeJSSession` also hides the node-path versus browser-bytes
handoff to a configurable JavaScript session factory.

## Inference

One named-tensor session API over every inference runtime, so a model SDK
builds its input tensors once and runs them unchanged on all platforms:

```swift
import Inference

let session = try inferenceSession(modelPath: path)
let logits = try await session.run(
    inputs: [
        "input_ids": Tensor(int64: ids, shape: [1, ids.count]),
        "attention_mask": Tensor(int64: mask, shape: [1, ids.count]),
    ],
    outputs: ["logits"])[0]
let values = logits.float32Values ?? []
```

`Tensor` is raw bytes plus an element type (`int32`/`int64`/`float32`) and
shape; accessors copy out via memcpy, so large tensors are fine. Multiple
inputs and outputs are supported, and autoregressive models feed outputs back
as the next step's inputs. Backends: `CoreMLSession` on Apple,
`LiteRTSession` on Android/Linux, and `JSInferenceSession` over LiteRT.js on
wasm. Model SDKs use the public factory rather than naming a backend directly.

Model SDKs normally never name a backend: the session factory picks it, so a
model repo carries no platform conditionals, just per-platform artifact names:

```swift
let files = try await distribution.resolve()                 // ModelStore
let session = try await files.inferenceSession(
    model: artifactName, hostGlobal: "__MyModelHost")        // Core ML | LiteRT | JS host
// Custom deployments: inferenceSession(modelPath:) / inferenceSession(modelBytes:)
```

## PlatformSupport

Small shared runtime utilities so model code writes no platform or concurrency
plumbing:

- `environmentVariable(_:)` reads an env var without importing Foundation.
- `httpGET(_:)` / `httpPOST(_:body:contentType:)` / `httpRequest(...)` are an
  async HTTP client that delegates to each platform's own networking: URLSession
  on Apple/Linux, the host (java.net/OkHttp via `CHostBridge`) on Android, and
  the JS host's `fetch` (JavaScriptKit) on WebAssembly.
- `MessageError` gives an error type one `message`; it is `LocalizedError`
  wherever Foundation exists, so SDKs skip the per-platform conformance.
- `blockingValue(_:)` runs an async operation to completion on a synchronous FFI
  worker thread (never an app's main thread).
- `LazyLoader<Value>` loads a value once, on demand, sharing the single in-flight
  load with every caller and broadcasting its progress (monotonic `0...1`). Model
  SDKs use it to load/download the model lazily and single-flight:

  ```swift
  let loader = LazyLoader { progress in try await downloadAndBuildModel(progress) }
  let model = try await loader.value()      // loads on first use
  try await loader.run { fraction in … }    // or prefetch with progress
  ```

## HostBridge (Android JNI)

The reusable Swift JNI harness provides byte-array marshalling, checked thread
attachment, and host callbacks. `ai.desertant:core` packages that Kotlin host,
the `LoadedModel` shell, and one `libLiteRt.so` per supported ABI.

Each model AAR depends on core and contains one uniquely named JNI library, such
as `libEmoAndroid.so`. It implements the common `NativeModelApi` contract with
model-specific JNI symbols. Its C++ and Swift runtimes are linked statically, so
two model AARs have no colliding native files and Gradle packages LiteRT once.
The model AAR otherwise keeps only its public API and payload codec.

```kotlin
dependencies {
    implementation("ai.desertant:core:0.5.5")
}
```

The shared shell creates the opaque handle, checks offline availability, moves
download and inference off the main thread, preserves each SDK's exception
type, guards use after close, and releases the handle exactly once.

Build and publish the artifact with mise (reproducible; provisions the Android
SDK on first run): `mise run build-android`, `mise run publish-android`
(Maven Central), or `mise run publish-android-local` (keyless, to `~/.m2`, for
testing consumers). The version is single-sourced in `kotlin/build.gradle.kts`
(`mise run set-version X.Y.Z`).

### Releasing

The repo ships two published sibling artifacts alongside the SwiftPM package:
the `ai.desertant:core` Android library (`kotlin/`) and the
`@desert-ant-labs/core` npm package (`js/`, the shared JavaScript runtime the
model node packages build on). Releases are tag-driven and publish only what
changed.

Bump the version whenever you like (it sets every artifact, so their versions
stay current and aligned), commit to `main`, then push a matching `vX.Y.Z` tag:

```bash
mise run set-version 0.3.2   # bumps kotlin/build.gradle.kts, js/package.json, README
# commit and merge to main
git tag v0.3.2 && git push origin v0.3.2
```

Three workflows react to the tag, each independent, and each publishes its
artifact only if it actually changed:

- `Publish Android` (`.github/workflows/publish-android.yml`) runs
  `mise run publish-android` when the tag matches the `kotlin/build.gradle.kts`
  version **and** `kotlin/` changed since the previous tag.
- `Publish npm` (`.github/workflows/publish-npm.yml`) runs `mise run publish-npm`
  when the tag matches the `js/package.json` version **and** `js/` changed since
  the previous tag.
- `Publish Gradle plugin` (`.github/workflows/publish-gradle-plugin.yml`) runs
  `mise run publish-plugin` when the tag matches the
  `gradle-plugin/build.gradle.kts` version **and** `gradle-plugin/` changed since
  the previous tag.

Credentials are **Desert-Ant-Labs organization secrets**, shared by every SDK
repo so there is a single place to rotate them: `MAVEN_CENTRAL_USERNAME`,
`MAVEN_CENTRAL_PASSWORD`, `SIGNING_IN_MEMORY_KEY`,
`SIGNING_IN_MEMORY_KEY_PASSWORD`, and `NPM_TOKEN`. They use visibility `all`, so
a **new model SDK repo publishes with no secret setup at all** - it just needs
the publish workflows:

```bash
gh secret set MAVEN_CENTRAL_USERNAME --org Desert-Ant-Labs --visibility all
```

Note that GitHub has no "public repositories only" scope (visibility is `all`,
`private`, or `selected`), so `all` also exposes these to the org's private
repos. Any workflow in any org repo can therefore read the publish credentials;
they are not readable from fork pull requests. Rotate via the same command.

The `maven-central` and `npm` environments hold **no** secrets; they are kept
only as optional approval gates (add required reviewers to gate a release) and
for deployment history. Do not add secrets to them - environment secrets shadow
organization ones.

A **pure version bump does not count as a change**, so a blanket `set-version`
that touches nothing but version lines republishes nothing. An artifact that did
not change is simply skipped and keeps its last published version, so **published
versions may skip** (e.g. the Android artifact can go from `0.3.0` straight to
`0.3.3` while the npm package publishes the in-between versions). npm and Maven
Central versions are immutable, so a given version never republishes. No local
secrets are needed to cut a release. To publish by hand instead, run
`mise run publish-android` / `mise run publish-npm` with the credentials
exported (for example via a gitignored `mise.local.toml`).

The JavaScript runtime is documented in [`js/README.md`](js/README.md); build
and test it locally with `mise run test-js`.

## Android wiring

On Android, `Regex`/`JSON`/`AudioIO` call `host_regex_matches` /
`host_json_parse` / `host_audio_decode` from `CHostBridge`; `HostBridge`'s
`installHostBridge` installs the implementations once via
`host_set_regex_matches` / `host_set_json_parse` / `host_set_audio_decode`,
wired to the shared `HostBridge.kt` statics (`regexMatches` / `jsonParseTree` /
`audioDecode`) in the published `ai.desertant:core` artifact, so a model SDK
vendors none of them. See `Sources/CHostBridge/include/CHostBridge.h` for the
contract.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for
most apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.
