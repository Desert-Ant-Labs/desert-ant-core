# desert-ant-core

Reusable, cross-platform Swift building blocks shared by Desert Ant Labs'
on-device model SDKs (redact, emo, shapes, ...).

Each module exposes one small public API and picks a per-platform backend behind
it, so the code that uses it never sees a platform `#if`:

| Module | API | Apple / Linux | Android | WebAssembly |
|---|---|---|---|---|
| `Regex` (type `Pattern`) | stdlib-`Regex`-shaped matching | `NSRegularExpression` | `java.util.regex` (via `CHostBridge`) | JS `RegExp` |
| `JSON` | `Codable` decoding | `Foundation.JSONDecoder` | host JSON parser (via `CHostBridge`) | JS `JSON.parse` |
| `TextNormalization` | `String.nfkc` | Foundation `precomposed...` | platform ICU `unorm2` (`libicu`) | JS `String.normalize` |
| `FFIBuffer` | length-prefixed typed C-ABI buffer | same on every platform | | |
| `HostBridge` | Android JNI harness for model SDKs | empty | JNI marshalling + installs `CHostBridge` | empty |
| `CHostBridge` | generic host-callback C bridge | - | installed by `HostBridge` | - |
| `ModelStore` | verified Hub downloads and `StoredModel` access | URLSession + FileManager | host HTTP + POSIX | JS fetch + node fs / memory |
| `ModelResources` | SwiftPM bundle file loading | Foundation Bundle | - | - |
| `Inference` | named-tensor `InferenceSession` (`Tensor` in/out) | `CoreMLSession` (Core ML) | `ORTSession` (ONNX Runtime C API) | `JSInferenceSession` (JS host session) |
| `PlatformSupport` | env access, blocking FFI bridge, `LazyLoader` | native C runtime | native C runtime | WASI libc |

The design deliberately avoids linking Foundation on Android and wasm (it would
add a ~40 MB ICU blob); instead it calls the host platform's own regex/JSON,
which are already loaded. See each module's source header for details.

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
```

Same shape as `Foundation.JSONDecoder`. On Apple/Linux it wraps Foundation's; on
Android/wasm it drives standard-library `Codable` over a JSON tree the host
parses (no Foundation, no hand-rolled grammar). Input is `String`/`[UInt8]`
because `Data` is Foundation-only.

## TextNormalization

```swift
import TextNormalization

let normalized = text.nfkc   // Unicode NFKC, using the platform's own normalizer
```

Text models normalize before tokenizing (SentencePiece/XLM-R expect NFKC).
Each platform already ships a normalizer, so this bundles no ICU where the OS or
host provides one: Foundation on Apple/Linux, the platform ICU (`unorm2`, via
`CAndroidICU` / `libicu`, API 31+) on Android, `String.prototype.normalize` on
wasm.

## FFIBuffer

A model core with a C ABI returns results as a self-describing binary payload
instead of JSON, so neither side hand-rolls a parser. `FFIWriter` builds a
big-endian, length-prefixed buffer (`u32`/`u64`/`f64`/length-prefixed UTF-8
strings); the host reads it with its own standard library (see the matching
`FfiReader` in `kotlin/HostBridge.kt`, a thin `java.nio.ByteBuffer` cursor) and
frees it with `ffiFree`. The payload *schema* is the model's own concern.

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
        .linux: ["model.onnx", "tokenizer.bin", "labels.json"],
    ]
)
let files = try await distribution.install()          // download + cache
// Or bypass download and caching entirely:
let local = try distribution.load(from: "/path/to/model-directory")
let tokenizer = try files.read("tokenizer.bin")
let modelPath = files.path("model.onnx")
```

`ModelResources.BundledResources` provides the same bytes, text, and path
operations for model files shipped in a SwiftPM resource bundle. On wasm,
`StoredModel.initializeJSSession` also hides the node-path versus browser-bytes
handoff to a configurable JavaScript session factory.

## Inference

One named-tensor session API over every inference runtime, so a model SDK
builds its input tensors once and runs them unchanged on all platforms:

```swift
import Inference

let session: InferenceSession = try ORTSession(modelPath: path)   // or CoreMLSession / JSInferenceSession
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
as the next step's inputs. Backends: `CoreMLSession` (Apple, configurable
`MLModelConfiguration`), `ORTSession` (Android/Linux, path or in-memory bytes;
the consuming binary links `libonnxruntime.so`), and `JSInferenceSession`
(wasm; the JS host owns the session and exposes `run(inputs)` on a per-model
host global). The backends are integration-tested by the model SDKs that use
them (e.g. redact), since exercising ORT/Core ML needs their runtimes.

Model SDKs normally never name a backend: the session factory picks it, so a
model repo carries no platform conditionals, just per-platform artifact names:

```swift
let files = try await distribution.resolve()                 // ModelStore
let session = try await files.inferenceSession(
    model: artifactName, hostGlobal: "__MyModelHost")        // CoreML | ORT | JS host
// Bundled deployments: inferenceSession(modelPath:) / inferenceSession(modelBytes:)
```

## PlatformSupport

Small shared runtime utilities so model code writes no platform or concurrency
plumbing:

- `environmentVariable(_:)` reads an env var without importing Foundation.
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

The reusable Swift JNI harness every Android model SDK repeats: byte-array
marshalling (`hostCopyBytes` / `hostMakeBytes` / `withHostCText` /
`hostTakeBuffer`), the `GetEnv`-checked thread attach, and `installHostBridge`,
which wires the `CHostBridge` regex/JSON callbacks to a host class's static
`regexMatches` / `jsonParseTree` methods (see `kotlin/HostBridge.kt`, the Kotlin
counterpart model SDKs vendor until a core Android artifact is published). A
model keeps only its own `@_cdecl("Java_...")` entry points. Empty off-Android.

## Android wiring

On Android, `Regex`/`JSON` call `host_regex_matches` / `host_json_parse` from
`CHostBridge`; `HostBridge`'s `installHostBridge` installs the implementations
once via `host_set_regex_matches` / `host_set_json_parse`. See
`Sources/CHostBridge/include/CHostBridge.h` for the contract.
