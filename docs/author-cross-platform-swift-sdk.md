# Authoring a cross-platform on-device model SDK (from a trained model)

This is a complete, agent-followable guide for turning a **trained model** into a
**single cross-platform Swift package** that ships to **Apple (SwiftPM / Core
ML), Android (Maven / LiteRT), and Web + Node (npm / LiteRT.js)** from one
codebase, with the pipeline written once in pure Swift.

It assumes **no existing SDK**: you have a checkpoint (and probably an ONNX /
Core ML export), and you want the full product surface. If you already have
separate `<model>-swift` / `-kotlin` / `-js` SDKs and want to consolidate them,
read `migrate-sdk-to-cross-platform-swift.md` instead (it references this doc for
the target architecture).

The canonical reference implementation is **`Desert-Ant-Labs/redact`**. When in
doubt, read that repo; every pattern below is live there.

---

## 0. Mental model (read this first)

There is exactly **one repo**, `<model>` (e.g. `redact`), which *is* a SwiftPM
package at its root and *also* contains the Android and web packages under
`packages/`. All three platforms run the **same Swift pipeline**; platform
variation is **data, not code**:

- The pipeline (`Sources/<Model>`) is **pure Swift** and never names a platform
  API. It builds named input tensors, runs an `InferenceSession`, reads named
  output tensors, and does the pre/post-processing.
- The **inference backend** is chosen by `desert-ant-core`'s session factory:
  Core ML on Apple, **LiteRT** (`.tflite`) on Linux/Android, **LiteRT.js** in
  the browser. The pipeline is oblivious to which.
- The **cross-platform primitives** (regex, JSON, Unicode normalization, model
  download/cache, FFI buffers, the Android JNI harness) come from
  `desert-ant-core`, which has a per-platform backend behind each API so the
  pipeline writes **zero** platform conditionals.
- The **model artifact** differs per platform (`.mlmodelc` for Apple, `.tflite`
  everywhere else) but is the *same weights*; it is downloaded from the Hugging
  Face Hub at a pinned revision, or bundled opt-in.

If you keep the pipeline free of platform APIs and free of Foundation (Foundation
would drag ~50 MB of ICU onto Android), everything else is plumbing that already
exists in `desert-ant-core` and in the redact reference.

---

## 1. The dependency: `desert-ant-core`

`desert-ant-core` is the shared, cross-platform foundation. You depend on it as a
**tagged** SwiftPM package (never `main` — see §12). Its modules:

| Module | Public API | Per-platform backend |
|---|---|---|
| `Regex` | `Pattern` (stdlib-`Regex`-shaped) | NSRegularExpression \| `java.util.regex` (via `CHostBridge`) \| JS `RegExp` |
| `JSON` | `JSONDecoder` (Codable) | Foundation \| host JSON tree \| `JSON.parse` |
| `TextNormalization` | `String.nfkc` etc. | Foundation \| Android ICU `unorm2` \| `String.normalize` |
| `ModelStore` | verified Hub download + `StoredModel`, `ModelDistribution` | Foundation \| Android \| WASI/JS host |
| `ModelResources` | `BundledResources` (SwiftPM bundle reads) | Foundation |
| `Inference` | `Tensor`, `InferenceSession`, `inferenceSession(...)` factory | Core ML \| LiteRT \| ONNX Runtime \| JS host |
| `PlatformSupport` | env access, sync↔async bridge (`blockingValue`), `MessageError` | per-OS |
| `FFIBuffer` | `FFIWriter` length-prefixed typed C-ABI buffer | shared |
| `HostBridge` | Android JNI harness (byte marshalling, thread attach, installs callbacks) | Android only |
| `CHostBridge` | generic host-callback bridge a runtime shim installs | C |
| `CLiteRt` / `COnnxRuntime` | vendored C headers + shim for the runtime | Android/Linux |

### 1.1 The inference seam (the heart of it)

`Sources/Inference` gives you two types and one factory. **This is the only way
the pipeline touches the model.**

- **`Tensor`** — a dense tensor in host byte order. Element types: `int32`,
  `int64`, `float32`. Built with `Tensor(int32:shape:)`, `Tensor(float32:shape:)`,
  etc.; read with `.float32Values`, `.shape`.

- **`InferenceSession`** — `func run(inputs: [String: Tensor], outputs: [String]) async throws -> [Tensor]`.
  Named tensors in, requested named tensors out (in order). Create once, reuse.

- **The factory** (`SessionFactory.swift`) picks the backend:
  ```swift
  // From a file on disk (Apple = Core ML .mlmodelc; Android/Linux = .tflite/.onnx):
  inferenceSession(modelPath: path)
  // From in-memory bytes (Android bundled classpath resource):
  inferenceSession(modelBytes: bytes)
  // From a resolved StoredModel (handles wasm's JS-host session too):
  storedModel.inferenceSession(model: artifact, hostGlobal: "__<Model>Host")
  ```
  Selection:
  - `#if canImport(CoreML)` → `CoreMLSession`
  - `#elseif DAL_LITERT` → `LiteRTSession` (opt-in, see §7)
  - `#elseif canImport(COnnxRuntime)` → `ORTSession` (the default off-Apple)
  - `#if os(WASI)` → `JSInferenceSession` (the JS host owns the session)

**Consequence:** the pipeline calls `session.run(inputs: ["input_ids": ...],
outputs: ["logits"])` and never knows or cares which runtime executed it. The
input/output **names must match the exported model's signature** on every
platform (§6.3).

---

## 2. Target repo layout

Create the repo `Desert-Ant-Labs/<model>` (private by default). Its layout,
mirroring redact:

```
<model>/                          # SwiftPM package root
  Package.swift                   # products/targets (split into typed lets — §11.1)
  Package.resolved
  mise.toml                       # build / test / publish tasks (§10)
  README.md  LICENSE.md  THIRD_PARTY_NOTICES.md
  Vendor/                         # gitignored; libLiteRt.so per platform (fetched by mise)
  Sources/
    <Model>/                      # the pure-Swift pipeline (the shared core)
      <Model>.swift               # public API: types, `class <Model>`, load/run entry
      Model.swift                 # tensor layout(s): builds inputs, runs session, reads outputs
      ModelLoading.swift          # artifact names, per-platform file manifest, ModelAssets
      Pipeline.swift, Tokenizer.swift, ... # model-specific pre/post-processing
    <Model>CoreMLResources/       # opt-in Apple bundle: redact.mlmodelc + sidecars
      Resources/<model>.mlmodelc/ …
      <Model>CoreMLResources.swift   # `enum …Bundle { static var bundle { .module } }`
    <Model>TFLiteResources/       # opt-in Linux/Android/Windows bundle: <model>.tflite + sidecars
      Resources/<model>.tflite …
      <Model>TFLiteResources.swift
    <Model>Android/               # C ABI + Swift JNI (no C shim)
      CABI.swift                  # @_cdecl <model>_create/_run/_destroy…, Foundation-free
      AndroidJNI.swift            # @_cdecl Java_ai_desertant_<model>_… entry points
    <Model>Web/                   # wasm entry point (#if os(WASI))
      main.swift                  # installs globalThis.__<Model>Exports {load, <run>}
  Tests/<Model>Tests/
    <Model>Tests.swift            # deterministic + end-to-end (bundled model)
    Resources/…                   # deterministic corpus fixtures
  packages/
    <model>-kotlin/               # Android AAR (Gradle)
      build.gradle.kts            # ai.desertant:<model>, vanniktech maven-publish
      settings.gradle.kts         # includes :<model>-tflite-resources
      swift-android.gradle.kts    # runs `mise run android-natives` before packaging
      <model>-tflite-resources/   # optional bundled-model artifact (classpath resources)
      src/main/kotlin/ai/desertant/<model>/{<Model>.kt, <Model>Native.kt}
      src/main/kotlin/ai/desertant/core/HostBridge.kt   # vendored from desert-ant-core
      src/main/jniLibs/<abi>/…    # gitignored; built by android-natives
      src/androidTest/…/RedactTest.kt   # instrumented test
    <model>-node/                 # npm package (@desert-ant-labs/<model>)
      index.js  index.d.ts        # the JS host: installs globalThis.__<Model>Host, public class
      dist/                       # gitignored; built by `mise run build-web` (RedactWeb.wasm + glue)
      package.json                # peerDependency @litertjs/core; files: [index.js, index.d.ts, dist, LICENSE.md]
      test/<model>.test.mjs
  Examples/
    <Model>SwiftExample/  <Model>AndroidExample/  <Model>WasmExample/
```

**Naming:** the SwiftPM library is `<Model>` (PascalCase, e.g. `Redact`); the
Android package namespace is `ai.desertant.<model>`, Maven coordinates
`ai.desertant:<model>` and `ai.desertant:<model>-tflite-resources`; the npm scope
is `@desert-ant-labs/<model>`; the HF model repo is `desert-ant-labs/<model>`.

---

## 3. Write the shared pipeline (`Sources/<Model>`)

This is the only genuinely model-specific code. Rules:

1. **No platform imports.** Use `Regex`, `JSON`, `TextNormalization`,
   `RealModule` (swift-numerics, for `exp`/`log` — the stdlib has no
   transcendentals and you must not import a per-OS libm or Foundation on
   Android). Do the softmax/etc. with `RealModule`.
2. **No Foundation** in the hot path (it is absent on Android). The one allowed
   place is the `#if canImport(CoreML) || os(Linux)` block for the opt-in
   `init(bundle:)` (Foundation's `Bundle` only exists where SwiftPM resource
   bundles do).
3. **Inference only through `InferenceSession`** with named tensors.

Key files:

- **`<Model>.swift`** — public value types (`<Model>ion`/result, `Options`,
  `<Model>Error: MessageError`) and `public final class <Model>`. The class holds
  a lazily-resolved model and exposes async methods (`load`/`download`,
  `redaction(of:)`/`recognize(...)`, etc.). Mirror redact's `Redaction`, `Item`,
  `Options`, `restore(_:)`.

- **`Model.swift`** — the `InferenceSession` wrapper. It owns tokenization,
  windowing, decoding, and the single `logits(ids:)`-style method that:
  ```swift
  let out = try await session.run(
    inputs: ["input_ids": Tensor(int32: ids, shape: [1, seq]),
             "attention_mask": Tensor(int32: mask, shape: [1, seq]),
             /* extra inputs the export bakes in are ignored by the session */],
    outputs: ["logits"])[0]
  ```
  Keep the tensor layout **fixed-shape** (e.g. a fixed 256 window) — the LiteRT
  shim uses fixed host buffers (§7), and Core ML exports fixed windows anyway.
  If both your Core ML and LiteRT exports use the same layout, do **not** invent
  a per-artifact `enum ModelLayout`; a single code path is cleaner (redact had a
  vestigial one-case enum after its migration and it was removed).

- **`ModelLoading.swift`** — the manifest and asset loading:
  ```swift
  enum <Model>Model {
    static let tokenizer = "<model>_tokenizer.bin"
    static let labels = "labels.json"
    static let tflite = "<model>.tflite"    // LiteRT platforms + wasm
    static let coreML = "<model>.mlmodelc"  // Apple
    static var artifact: String { ModelPlatform.current == .apple ? coreML : tflite }
  }

  public extension <Model> {
    static var modelRepo: String { "desert-ant-labs/<model>" }
    static var modelRevision: String { "vX.Y.Z" }   // pinned HF tag (§9)
    private static func distribution() -> ModelDistribution {
      let sidecars = [<Model>Model.tokenizer, <Model>Model.labels]
      let tflite = [<Model>Model.tflite] + sidecars
      return ModelDistribution(repo: modelRepo, revision: modelRevision, files: [
        .apple: [<Model>Model.coreML + "/"] + sidecars,   // "/" = whole .mlmodelc dir
        .android: tflite, .linux: tflite, .windows: tflite, .web: tflite,
      ])
    }
  }
  ```
  `ModelAssets` bundles the sidecar bytes + a ready `InferenceSession`. Provide
  three ways to build it:
  - `ModelAssets.redact(files: StoredModel)` — from a resolved (downloaded or
    adopted) model directory, via `files.inferenceSession(model:hostGlobal:)`.
  - `ModelAssets(tokenizer:labelsJSON:modelBytes:)` — the **bindings** entry
    (Android reads bytes from classpath resources) via
    `inferenceSession(modelBytes:)`. Mark it `@_spi(<Model>Bindings) public`.
  - `ModelAssets.redact(bundle: Bundle)` — from a SwiftPM resource bundle
    (Apple/Linux opt-in), behind `#if canImport(CoreML) || os(Linux)`.

- **The download/resolve helpers** on `<Model>`: `resolvedAssets(directory:cacheRoot:progress:)`
  and `isModelAvailable(...)` call `distribution().resolve(...)` /
  `.isAvailable(...)`. `ModelDistribution` handles SHA-256 verified download,
  caching under a managed nested layout, and adopting an explicit directory.

---

## 4. The resource targets (opt-in app bundling)

Two thin targets so apps can ship the model instead of downloading:

- `<Model>CoreMLResources` (Apple) — copies `<model>.mlmodelc/`, tokenizer,
  `labels.json`, `<model>_meta.json`.
- `<Model>TFLiteResources` (Linux/Windows; Android uses a Gradle module instead)
  — copies `<model>.tflite` + the same sidecars.

Each has a one-line accessor:
```swift
import Foundation
public enum <Model>TFLiteResourcesBundle { public static var bundle: Bundle { Bundle.module } }
```
The public `<Model>(bundle:)` convenience init (in `ModelLoading.swift`, behind
`#if canImport(CoreML) || os(Linux)`) loads from a passed bundle. **The core
library does not depend on either resource target** — they're separate products
an app opts into, so the SDK ships without the model and downloads on demand by
default.

**These are git-tracked** (the `.mlmodelc` ~12 MB and `.tflite` ~24 MB are
committed directly, no LFS). jj's default 20 MB snapshot limit blocks the tflite;
run `jj config set --repo snapshot.max-new-file-size 26214400`.

---

## 5. `Package.swift`

Products: `<Model>` (the library), `<Model>CoreMLResources`,
`<Model>TFLiteResources`, `<Model>Android` (`type: .dynamic`), and `<Model>Web`
(wasm executable). Targets as in the layout. Two build-time switches:

```swift
// Android's static-stdlib link must have no swift-syntax macros in the graph,
// so drop JavaScriptKit + the wasm target for the Android build.
let noJavaScriptKit = ProcessInfo.processInfo.environment["SWIFT_ANDROID_STATIC_BUILD"] != nil
```

- Dependency: `.package(url: desert-ant-core, from: "X.Y.Z")` (a **tag**).
- The test target links `<Model>CoreMLResources` on Apple platforms and
  `<Model>TFLiteResources` on `[.linux, .windows]` (conditional targets).
- `<Model>Android` depends on `FFIBuffer`, and (`.when(platforms: [.android])`)
  `HostBridge` + `ModelStore`.

**⚠️ Manifest type-check timeout (real, hit on Xcode 26):** a single large
`Package(...)` literal with many conditional `+` array concatenations exceeds the
Swift manifest type-checker's budget on some toolchains ("unable to type-check
this expression in reasonable time"), which breaks **Apple** builds while Linux's
compiler tolerates it. **Extract `products`, `targets` (split library vs test)
into explicitly-typed top-level `let` constants** and pass them in. Verify with
`swift package dump-package` on **macOS**, not just Linux.

---

## 6. Export the model artifacts (in `<model>-training`)

You need two runnable exports from the **same checkpoint** that produced your
reference (torch) model, plus sidecars.

### 6.1 Sidecars (shared, platform-neutral)
- `<model>_tokenizer.bin` — the compact vocab your Swift `Tokenizer` reads.
- `labels.json` — `{"id2label": {...}}`.
- `<model>_meta.json` — public/deterministic labels, recommended thresholds.

### 6.2 Core ML (`<model>.mlmodelc`) — Apple
Convert with `coremltools` (jit.trace, eager attention, a fixed window, int32
inputs, baked position/type ids). Compress with `coremltools.optimize.coreml`
(palettize/linear-quantize) and pick the smallest package whose **PSNR of logits
vs fp32** clears the bar (8-bit > 50 dB, 4-bit ≥ 35 dB). Compile the `.mlpackage`
to `.mlmodelc` (`xcrun coremlcompiler compile`, on the Mac — see the GPU/Mac
notes in `AGENTS.md`).

### 6.3 LiteRT (`<model>.tflite`) — Linux / Android / Web
Use **`litert-torch`** (the renamed `ai-edge-torch`) + **`ai-edge-quantizer`** in
an isolated `uv` env (no GPU needed — CPU conversion). See
`redact-training/scripts/export_tflite.py` for a working script. Key points:

- **Signature must match `Model.swift`.** Redact uses two int32 inputs named
  **`input_ids`** and **`attention_mask`** at fixed `[1, 256]`, and one float32
  output named **`logits`** at `[1, 256, num_labels]`. To get those exact names:
  - Wrap the torch model so `forward(input_ids, attention_mask)` **bakes**
    `position_ids` (`arange(pad+1, pad+1+seq)`, matching the Core ML export) and
    `token_type_ids` (zeros) internally, casting int32→int64 inside for the
    embedding lookup. Two inputs is simpler than four; the LiteRT session ignores
    any extra inputs the pipeline passes.
  - **Return a dict** `{"logits": ...}` from the wrapper so the tflite output
    signature is named `logits` (not `output_0`).
  - Convert: `lt.convert(wrapper, sample_kwargs={"input_ids": torch.zeros(1,256,int32), "attention_mask": torch.ones(1,256,int32)})`,
    then `.export("<model>.tflite")`.
- **Quantize** with `ai_edge_quantizer` (no calibration for dynamic/weight-only
  recipes): sweep `dynamic_wi8`, `weight_only_wi8`, `dynamic_wi4`, blockwise int4.
  Verify each with the `ai_edge_litert.interpreter` **argmax agreement + PSNR vs
  the fp32 torch reference**. For a PII/classification model, **require exact
  argmax parity** (int4 per-channel usually drops it to ~94% — reject; int8
  keeps 1.0000 at ~24 MB, PSNR ~52 dB — ship that).
- Confirm names/shapes/dtypes: `Interpreter(model_path).get_signature_list()`.

### 6.4 Parity gate (must pass before shipping)
Argmax agreement + PSNR vs the fp32 torch reference, **and** span-for-span (or
task-metric) agreement of the full pipeline against your existing reference on a
deterministic corpus. The Swift tests (§8) are the on-device confirmation.

Upload the artifacts (`.tflite`, `.mlmodelc/`, sidecars) to the HF model repo at
a **new tag** (§9) and pin `modelRevision` to it.

---

## 7. LiteRT on Android/Linux (`DAL_INFERENCE_LITERT`)

`desert-ant-core` supports LiteRT behind the existing seam, **opt-in at build
time** via the `DAL_INFERENCE_LITERT` env var (default is ONNX Runtime, kept for
back-compat). SwiftPM re-evaluates the core dependency's manifest **in the
current process environment**, so exporting `DAL_INFERENCE_LITERT=1` in your
build/test commands flips core to `LiteRTSession`. **Set it for Android + Linux;
never for the Apple build** (Apple always uses Core ML).

### 7.1 Vendor `libLiteRt.so`
The consuming binary links `libLiteRt.so` (as the ORT path vendors
`libonnxruntime.so`). Sources:
- **linux-x64:** the `ai-edge-litert` pip wheel. Fetch reproducibly with
  `uv pip install --python-platform x86_64-manylinux_2_28 --python-version 3.12
  --target <tmp> --only-binary=:all: ai-edge-litert==2.1.6`; the `.so` is at
  `ai_edge_litert/libLiteRt.so`.
- **Android (per ABI):** the Maven AAR
  `com.google.ai.edge.litert:litert:2.1.6` on **Google's** maven
  (`https://dl.google.com/dl/android/maven2/...`). Each `jni/<abi>/libLiteRt.so`
  exposes the CompiledModel C API.
- **Pin 2.1.6.** 2.1.5 has a from-path load regression; older ones lack fixes.

Link with `-Xlinker -L<vendordir>`; at runtime set `LD_LIBRARY_PATH=<vendordir>`
(Linux). The `mise` `litert-libs` / `android-natives` tasks do this (§10).

### 7.2 CPU by default; GPU when its lib is bundled
`LiteRTSession`'s default accelerator is **`.auto`** (GPU|CPU): the GPU is used
automatically **iff** its accelerator `.so` is bundled with the app and usable,
else CPU/XNNPACK. The C shim retries CPU-only if GPU compilation fails, so
requesting GPU is always safe. **Practical rule:** ship `libLiteRt.so` only
(CPU/XNNPACK) unless the model needs the GPU; a CPU model that also ships the GPU
accelerator would run on a (software) GPU on headless Linux, which is slower. The
`--gpu` flag on the mise tasks opts a model in.

### 7.3 The from-bytes buffer-ownership rule (bug you must not reintroduce)
`LiteRtCreateModelFromBuffer` is **zero-copy**: the header says the caller must
keep the buffer valid for the model's lifetime. The Android **bundled** path
loads from bytes (`byte[]` → Swift `[UInt8]`), which is freed right after
session creation → the model's flatbuffer dangles → **SIGSEGV at run**. The core
C shim (`CLiteRt/shim.c`) **owns a malloc'd copy** of the bytes and frees it in
`dal_lrt_free`. This is fixed in core ≥ 0.2.3; just depend on a core tag that has
it. (File-path loads mmap and were never affected — this is why "works on Linux,
crashes on Android" happens.)

### 7.4 `LiteRTSession.run` is serialized
The shim owns one compiled model + one set of fixed host buffers, so a run (and
the output reads after it) is **not reentrant**. Core serializes `run` with a
mutex (≥ 0.2.1), matching the reentrant `InferenceSession` contract ORTSession
gets for free. Concurrent redactions on one session are therefore safe.

---

## 8. Tests per platform

- **`swift test`** covers Apple (Core ML, part of the OS) and Linux (LiteRT, with
  the vendored `.so` + `DAL_INFERENCE_LITERT=1`). Include: deterministic-recognizer
  parity vs a Python corpus, and end-to-end bundled-model redaction (`<Model>(bundle:)`).
- **Android instrumented** (`connectedDebugAndroidTest`): the bundled-model path
  on a device/emulator. **Do not trust the Apple-Silicon arm64 emulator for
  inference** — XNNPACK selects Armv9 **SME** microkernels the emulator advertises
  (HVF passthrough) but can't execute, causing `SIGILL`/`SIGSEGV` (documented:
  mediapipe #6293, XNNPACK #9898). Validate on a **physical arm64 device**, or an
  **x86_64 emulator on a KVM host** (x86_64 XNNPACK is conformant), or Firebase
  Test Lab. (Distinguish this from the buffer bug in §7.3, which crashes on *all*
  Android including real devices — that one is ours to fix.)
- **Web:** an npm test that runs the wasm core; LiteRT.js needs a browser, so the
  **Node test gracefully skips** and a **headless-Chromium** test validates the
  real path (see `Examples/<Model>WasmExample/`).

---

## 9. Hugging Face layout

- **Model repo** `desert-ant-labs/<model>` (product artifacts + card only):
  `<model>.tflite`, `<model>.mlmodelc/`, `<model>_tokenizer.bin`, `labels.json`,
  `<model>_meta.json`, and (optionally) `<model>.pt` as the torch reference.
  Tag each release (`vX.Y.Z`); **old tags are immutable**, so older SDK versions
  keep working. `<Model>.modelRevision` pins the tag the SDK downloads from.
- **Dataset repo** `desert-ant-labs/<model>-<data>` for training data.
- **Bucket** `desert-ant-labs/jobs-artifacts` for mutable job outputs
  (checkpoints/logs), under a `<model>/<run-id>/` prefix. Do **not** make
  per-checkpoint model repos.
- The **model card** (`README.md`) points to the one `<model>` repo for all
  platforms and lists the LiteRT/Core ML files. The **org card** lives in the
  `desert-ant-labs/README` **Space** (edited by uploading its `README.md`).

---

## 10. `mise.toml` (the build/test/publish entry points)

Single-source the release version from `packages/<model>-node/package.json`;
`set-version` propagates it to the two Gradle modules and the README, and
`check-version` asserts consistency. Pin the Swift toolchain in `[tools]` (the
wasm/Android cross-SDKs only exist for released Swift versions). The tasks
(copy from redact and rename):

- `litert-libs` (hidden) — fetch linux-x64 `libLiteRt.so` from the pip wheel into
  `Vendor/litert/lib/linux-x64` (idempotent). Uses mise `usage` flags
  (`--litert-version`, `--gpu`).
- `build-swift` / `test-swift` — Apple: plain `swift (build|test)`. Linux:
  `DAL_INFERENCE_LITERT=1 [LD_LIBRARY_PATH=…] swift (build|test) -Xlinker -LVendor/litert/lib/linux-x64` (depends on `litert-libs`).
- `android-natives` (hidden, invoked by Gradle) — the big one: installs the Swift
  Android SDK + NDK on demand, fetches the litert AAR per ABI, and for each of
  `arm64-v8a`/`x86_64` runs
  `swift build -c release --product <Model>Android --swift-sdk <arch>-unknown-linux-android$API -Xswiftc -static-stdlib -Xswiftc -resource-dir -Xswiftc <res> -Xlinker -LVendor/litert/lib/android-<arch>`
  with `SWIFT_ANDROID_STATIC_BUILD=1` and `DAL_INFERENCE_LITERT=1` exported,
  strips the `.so`, and copies `lib<Model>Android.so` + `libLiteRt.so` +
  `libc++_shared.so` into `jniLibs/<abi>`; then stages the model into the
  `<model>-tflite-resources` module. `--gpu` also ships the accelerator sibling.
- `build-web` — `swift package … --swift-sdk <wasm-sdk> js --product <Model>Web`,
  `wasm-opt -Oz`, and copy `<Model>Web.wasm` + the JS glue into `packages/<model>-node/dist`.
- `build-android` — `./gradlew assembleRelease` (triggers `android-natives`).
- `test`, `test-android`, `test-web`.
- `set-version <ver>` (mise `usage` arg), `check-version` (hidden).
- `publish-swift` — tag `vX.Y.Z` on `origin/main` + `gh release create` (SwiftPM
  releases are git tags; consumers pin `from:`).
- `publish-android` — `./gradlew publishAndReleaseToMavenCentral` (vanniktech
  plugin, in-memory GPG signing; creds from `mise.local.toml` as
  `ORG_GRADLE_PROJECT_*`).
- `publish-web` — `npm publish --access public` (token from `mise.local.toml`).

---

## 11. Gotchas checklist (things that will bite a new agent)

1. **`Package.swift` manifest type-check timeout on macOS** — split into typed
   `let`s (§5).
2. **`DAL_INFERENCE_LITERT` only where wanted** — Linux/Android yes, Apple no.
3. **libLiteRt 2.1.6**, not 2.1.5 (path-load regression).
4. **From-bytes buffer ownership** — depend on core ≥ 0.2.3 (§7.3).
5. **Fixed tensor shapes** — the LiteRT shim uses fixed host buffers.
6. **Signature names** — tflite `input_ids`/`attention_mask`→`logits` must match
   `Model.swift`'s tensor-dict keys exactly, or you get a clean runtime error.
7. **arm64 emulator ≠ real device** for XNNPACK (§8). Verify inference on real
   hardware or an x86_64 KVM emulator.
8. **Pure Swift, no Foundation on Android** (else ~50 MB ICU). The pipeline uses
   `Regex`/`JSON`/`TextNormalization`/`RealModule`.
9. **The `<model>-tflite-resources` module & jniLibs are gitignored** and
   produced by `android-natives`; the base AAR ships **no** model (downloads on
   demand).
10. **Core is a tag dependency** — cut/point at a core release, never `main`
    (§12).
11. **esm.sh/CDN can't serve the wasm-core SDK** (WASI + relative-asset loads
    break). Demos self-host the built `dist/` + LiteRT.js (see the demos doc/§13).
12. **HF org card** is the `desert-ant-labs/README` **Space**; **model card** is
    the model repo's `README.md`.

---

## 12. Order of operations (do it in this sequence)

1. **`desert-ant-core`**: if it lacks anything you need (a new backend, a fix),
   land it and **cut a tagged release** first; redact/your SDK depends on a tag.
2. **Export** `<model>.tflite` + `<model>.mlmodelc` + sidecars from the same
   checkpoint; pass the parity gate (§6.4).
3. **HF**: upload artifacts at a new model tag; note the tag for `modelRevision`.
4. **Repo scaffold**: copy redact's structure; rename `Redact`→`<Model>`,
   `redact`→`<model>`, `ai.desertant.redact`→`ai.desertant.<model>`,
   `@desert-ant-labs/redact`→`@desert-ant-labs/<model>`.
5. **Pipeline** (`Sources/<Model>`): port your pre/post-processing; wire inputs
   through `InferenceSession`.
6. **Resource targets** + `Package.swift` (typed-`let` split).
7. **Linux green first**: `mise run test-swift` (LiteRT) and macOS `swift test`
   (Core ML). This validates the shared core on both real backends fast.
8. **Web**: implement `Sources/<Model>Web/main.swift` + `packages/<model>-node/index.js`
   (LiteRT.js host); `mise run build-web`; validate in headless Chromium.
9. **Android**: `Sources/<Model>Android/{CABI,AndroidJNI}.swift` +
   `packages/<model>-kotlin/**`; `mise run android-natives`; instrumented test on
   a real/x86_64 device.
10. **Version + publish**: `mise run set-version X.Y.Z`, push `main`, then
    `publish-swift` → `publish-web` → `publish-android`.
11. **Docs/demos**: model card, org card, GitHub org profile, website catalog,
    HF demo Space + website demo widget — all pointing at the one `<model>` repo.

---

## 13. Demos (both consume the published SDK)

- **HF demo Space** `desert-ant-labs/<model>-demo` (`sdk: static`): an
  `index.html` + `main.js` that import `@desert-ant-labs/<model>` and (for LiteRT
  models) `@litertjs/core`, **self-hosted under `lib/`** (CDN breaks the wasm
  loading). `main.js` calls `<Model>.load({ litertWasmDir })` and
  `redactor.redaction(text)`. Deploy with `HfApi.upload_folder(...,
  repo_type="space")`.
- **Website widget** (in the `website` repo): `build/vendor.mjs` esbuild-bundles
  the SDK (with a plugin that **stubs the SDK's Node platform** so its `node:*`
  static imports don't poison the browser bundle) and self-hosts the WebAssembly
  core + LiteRT.js wasm under `/assets/vendor/`; the model's `demoWidget` in
  `data/models.json` is `{pkg, version, runtime: "litert"}`; `public/assets/demos.js`
  loads via `mod.<Model>.load({ litertWasmDir: "/assets/vendor/litert/" })`.
  Note: the website's i18n gate blocks the build on any changed English string
  (refresh all locale files), and its Node sample verifier must **skip** the
  browser-only LiteRT SDK.

---

## 14. Definition of done

- All four platforms green: macOS `swift test` (Core ML), Linux `mise run
  test-swift` (LiteRT), web browser E2E, Android instrumented on real hardware.
- Identical spans/outputs across platforms (argmax parity from the export).
- Published: SwiftPM tag + GH release, npm, Maven Central; HF model at a pinned
  tag; `modelRevision` set.
- Docs point at the one repo: model card, org card (`desert-ant-labs/README`
  Space), GitHub org profile, website catalog, both demos.
