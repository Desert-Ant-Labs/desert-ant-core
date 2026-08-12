# Building, testing, and releasing

Everything here is a [mise](https://mise.jdx.dev) task, so CI runs exactly what
you run locally. `mise tasks` lists them, `mise tasks info <name>` shows one, and
the scripts themselves are plain shell in [`mise-tasks/`](../mise-tasks) sharing
[`Tools/dal.sh`](../Tools/dal.sh).

```bash
mise run test          # everything this host can run without a device
mise run build         # everything this host can build
```

## The model list does not exist

No task, workflow, or build script names the models. They are discovered:

| Question | Answer |
|---|---|
| What models are there? | `Sources/<Product>/Catalog.swift` |
| Which ship an npm package? | `packages/<model>-node/` exists |
| Which ship a Maven AAR? | `packages/<model>-kotlin/` exists |
| What is the Swift graph? | `Package.swift` (one `models` array) |
| What is the Gradle build? | `settings.gradle.kts` globs `packages/*-kotlin` |

So adding a model is adding directories. CI picks it up with no edit.

## What a model writes by hand

The Swift pipeline, and as little else as possible. Everything that crosses a
language boundary is generated from a Swift declaration:

| Crossing | Written | Generated |
|---|---|---|
| wasm -> JS (the ABI) | `Sources/WasmBindings/Exports.swift`, once for all models | `dist/bridge-js.{js,d.ts}` per package |
| JS -> wasm (the host) | `Sources/JSHost/Host.swift`, once for all models | the `Imports` type the JS seam satisfies |
| The model's own facts | `Sources/<Product>/Catalog.swift` | `modelInfo()`, which the JS SDK reads at load |

So a model's wasm entry point is one `installWasmModel` call, its npm package
restates no file names or host names, and the payload codecs
(`Binding.swift` <-> `codec.js`) are the only per-model marshalling left.

### Modality is a payload, not an entry point

There is one run entry on every ABI:

```swift
func run(input: FFIReader, options: FFIReader) async -> [UInt8]?
```

`input` is the model's own payload, exactly as `options` and the result already
were. Text is `string text`; Clear's audio is `f32Array samples, f64 sampleRate`;
a video model is whatever it says it is. Nothing about the modality reaches
`dal_run`, the wasm exports, the JNI entry, `NativeModelApi`, or the JS core, so a
new kind of input adds no symbol in any language - it is a schema in the model's
`Binding.swift` and its host codec, which every model writes anyway for its
options and its result.

That is what replaced `run(text:)` plus `run(audio:sampleRate:)`, and with them
`dal_run_audio`, `runAudio` in the wasm exports, Clear's second JNI entry, and the
two defaulted protocol witnesses that reported "not this model's input". The
Android path had already made the argument: it encoded audio as a payload, decoded
it in Swift, and handed the pieces to a typed entry the model then re-read.

### Adding a model

The Swift pipeline, plus per host a wrapper that knows only this model's payload
schemas and its public API:

| Where | What | Emo today |
|---|---|---|
| Swift | the pipeline, `Catalog.swift`, `Binding.swift` (3 payload schemas), `Native.swift` (symbol names), `Web/main.swift` (one call) | 183 lines outside the pipeline |
| JS | `codec.js` (the same 3 schemas), the public class, its types, four wiring files of ~5 real lines each | 274 lines |
| Kotlin | the public class, its `*Native` object (5 `external fun` declarations) | 111 lines |

No host restates the model's id beyond `MODEL_ID` (the native ABI takes it as an
argument), its file names, its host global, or its ABI: those come from
`modelInfo()`, the generated `Imports`, and the generated `bridge-js.d.ts`.

### What a long-running model will need

A model that processes a whole file (Clear) works through this, but three
assumptions in the ABI are sized for one short call, and they are the same on the
C ABI, so changing them is one cross-language decision rather than a wasm patch:

- **No progress channel.** `Clear.Progress(phase:fraction:)` exists in Swift and
  cannot cross either ABI; the JS native path fakes download progress by
  reporting the endpoints. wasm could take a closure today (BridgeJS supports
  one, as `download` does); C and JNI would need a callback argument to match.
- **No cancellation.** A long run cannot be stopped from the host on any
  platform.
- **Whole payloads cross by copy.** The input payload carries the whole buffer, so
  a long file is copied into wasm memory and its result copied back, under a
  32-bit address space. Note the asymmetry this creates: `Clear.enhanceStreaming`
  already processes a file window by window with bounded memory *inside* Swift, and
  reports `Progress` while it does, so the ABI is now the only thing forcing a
  whole file through memory at once. A chunked entry point (a window in, a window
  out) would let a host reuse the streaming path that already exists, and would
  answer the progress and cancellation points above at the same time.

The wasm host contract has a related limit: it holds one compiled model per
module, so the multi-session concurrency `Clear` uses natively
(`ModelAssets(sessions:)`) degrades to a single session on the web.

Tasks that act per model take a model argument, defaulting to `all`:

```bash
mise run build:swift emo
mise run build:wasm redact
mise run test:node
```

## Platforms and what covers them

The point of CI is one question: does every model still work on every platform?

| Platform | Runtime | Task | CI job |
|---|---|---|---|
| macOS, iOS, tvOS, visionOS | Core ML | `test:swift`, `test:ios` | `apple` |
| Linux | LiteRT | `test:swift` | `linux` |
| Browser | WebAssembly + LiteRT.js | `test:wasi`, `build:wasm`, `test:browser`, `test:bundles` | `js` |
| SSR (framework server pass) | none - must import cleanly | `test:node`, `test:bundles` | `js` |
| Node (server-side inference) | prebuilt native core | `build:node-native`, `test:node` | `js`, `darwin-native` |
| Android | LiteRT | `build:android`, `test:android` | `android` |

Every model with an npm package runs real inference in a real browser
(`test:browser`, headless Chromium), not just a bundle that compiles. Models with
no npm or Maven package (Clear and Clips today) are Apple + Linux + a wasm
compile check; that is intentional, since there is no artifact to test.
Model-backed tests are disabled on iOS and WASI by `runsModelBackedTests`, so
`test:ios` proves the package compiles and its non-model logic works while macOS
covers Core ML inference.

Plus two invariants, in the `checks` job:

- `check:version` - every artifact carries the version in `VERSION`.
- `check:isolation` - a model's Swift graph contains no other model, and no
  audio stack unless it imports one. An app that adds one SDK pays for that SDK
  alone, and this reads the resolved SwiftPM graph, so it cannot be fooled by an
  incremental build.
- `check:swift-floor` - the package builds on the oldest Swift the README
  promises (6.2). Nothing checked this before, so the claim drifted twice: it said
  5.9 while `nonisolated(unsafe)` (5.10) and later typed throws (6.0) were already
  in code every consumer parses. Parsing covers the Apple-only and Android-only
  branches too, since Swift parses inactive `#if` blocks; type-checking those needs
  the `apple` job.
- `check:types` - the `.d.ts` files that ship to npm compile, and the two
  contracts core restates are identical to the ones BridgeJS generates from
  Swift: `WasmCore` against the exports a core provides
  (`Sources/WasmBindings/Exports.swift`) and `HostImports` against the host it is
  instantiated with (`Sources/JSHost/Host.swift`). Core is model-agnostic so it
  cannot import a model package's generated `dist/bridge-js.d.ts`, and those
  restatements are the types here that can drift from Swift silently. Where a
  model core has been built (the `js` job, or after `build:wasm`) this also
  catches a stale `dist`.

CI pins each job to the runner the release publishes from, so the toolchain that
ships is the one CI proves: `ubuntu-22.04` for the Linux natives (glibc 2.35) and
`macos-14` for the darwin native (an older Swift than the `apple` job's
`macos-26`, and bash 3.2 rather than 5.x). Building a shipped artifact on a
newer image than the release uses proves the wrong thing.

## Toolchains

Three Swift toolchains are in play and none may share a SwiftPM scratch
directory, because their artifacts are mutually incompatible:

| Toolchain | Used by | Scratch |
|---|---|---|
| Xcode / the system toolchain | `test:swift`, `build:swift`, `build:node-native` | `.build-host` |
| pinned swift.org release | `test:wasi`, `build:wasm` | `.build` (the js plugin requires the default) |
| pinned swift.org release | `test:android` | `.build-androidtest` |
| swift.org 6.4 snapshot | `build:android-natives` | `.build-android` |

mise provisions the pinned toolchains, the JDK, Node, and wasm-opt. The Android
SDK, Swift cross-compilation SDKs, NDK, and LiteRT runtimes install on demand on
first use and are cached in CI.

## Gradle

One build at the repo root covers every publishable Android artifact:

```
:core          kotlin/                  -> ai.desertant:core
:<model>       packages/<model>-kotlin/ -> ai.desertant:<model>
gradle-plugin/ (included build)         -> ai.desertant:model-sdk-gradle-plugin
```

Model modules depend on `project(":core")` and apply the convention plugin from
the included build, so a model AAR builds from a clean checkout with nothing
published. The generated POM still says `ai.desertant:core:<version>`, because
that is core's identity. `androidtest/` stays a separate build: it is a test
harness, not an artifact, and pins its own AGP/Kotlin.

## Versioning

`VERSION` at the repo root is the single source. Gradle reads it directly, so no
build script carries a version literal. `mise run set-version X.Y.Z` writes
`VERSION` plus the formats that cannot read a file (`package.json`,
`Catalog.swift`, the README install snippets), and `mise run check:version`
proves they still agree.

## Releasing

Push a tag. That is the whole flow:

```bash
mise run set-version 1.2.3
jj commit -m "Release 1.2.3"
jj git push
git tag v1.2.3 && git push origin v1.2.3
```

`.github/workflows/release.yml` then publishes everything at that version:

| Artifact | Where |
|---|---|
| The tag itself | the SwiftPM release, plus a GitHub Release |
| `ai.desertant:{core,model-sdk-gradle-plugin,<model>...}` | Maven Central |
| `@desert-ant-labs/{core,<model>...}` | npm |

There is no per-artifact change detection and no ordering to arrange: one
version covers the repo, so everything ships together. Every publish task is
re-runnable - anything already live at that version is skipped - so a half-failed
tag is fixed by re-running the workflow. A `workflow_dispatch` run builds every
publishable artifact and publishes none, which is the way to exercise the heavy
cross-compiles without cutting a release.

Credentials are Desert-Ant-Labs organization secrets (`MAVEN_CENTRAL_*`,
`SIGNING_IN_MEMORY_*`, `NPM_TOKEN`), so there is one place to rotate them. For
local publishing, put them in `mise.local.toml`.

## npm workspace

`package.json` at the root is a private workspace over `js/` and
`packages/*-node`, so `npm install` links the **local** core into every model
package. That is deliberate: the model suites and the bundle matrix must test the
core in this checkout, not whatever the registry last published. The published
packages still depend on `@desert-ant-labs/core` with a caret, so two models
installed from different releases dedupe to one copy.
