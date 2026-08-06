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
| Node (server-side inference) | prebuilt native core | `build:node-native`, `test:node` | `js` |
| Android | LiteRT | `build:android`, `test:android` | `android` |

Every model with an npm package runs real inference in a real browser
(`test:browser`, headless Chromium), not just a bundle that compiles. Models with
no npm or Maven package (Clear today) are Apple + Linux + a wasm compile check;
that is intentional, since there is no artifact to test. Model-backed tests are
disabled on iOS and WASI by `runsModelBackedTests`, so `test:ios` proves the
package compiles and its non-model logic works while macOS covers Core ML
inference.

Plus two invariants, in the `checks` job:

- `check:version` - every artifact carries the version in `VERSION`.
- `check:isolation` - a model's Swift graph contains no other model, and no
  audio stack unless it imports one. An app that adds one SDK pays for that SDK
  alone, and this reads the resolved SwiftPM graph, so it cannot be fooled by an
  incremental build.

## Toolchains

Three Swift toolchains are in play and none may share a SwiftPM scratch
directory, because their artifacts are mutually incompatible:

| Toolchain | Used by | Scratch |
|---|---|---|
| Xcode / the system toolchain | `test:swift`, `build:swift`, `build:node-native` | `.build-host` |
| pinned swift.org release | `test:wasi`, `build:wasm`, `test:android` | `.build` (the js plugin requires the default) |
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
