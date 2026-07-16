# Migrating an existing model SDK to the cross-platform Swift package

This is a complete, agent-followable guide for consolidating an existing model
that ships as **three separate per-platform SDKs** — `<model>-swift`,
`<model>-kotlin`, `<model>-js` — into **one cross-platform Swift package**
(`<model>`) where the pipeline is written once in pure Swift and all three
platforms (Apple / Android / Web) build from it.

This is exactly what was done for **`redact`**: `redact-swift` became the unified
`Desert-Ant-Labs/redact` repo (with `packages/redact-kotlin` and
`packages/redact-node` inside it), and `redact-kotlin` / `redact-js` were
archived with "moved to the unified repo" READMEs.

For the **target architecture** (module map, the `InferenceSession` seam, the
`desert-ant-core` dependency, `mise.toml`, HF layout, gotchas), read
`author-cross-platform-swift-sdk.md` — this doc assumes it and focuses on the
**migration deltas**: what you already have, what to reuse vs. rewrite, and the
order that avoids breaking published consumers.

There are two flavors of migration:

- **A. Consolidation only** — the three SDKs already share a model/runtime and
  you're just merging the repos into one. Lower risk.
- **B. Consolidation + runtime change** — you also switch the non-Apple runtime
  (e.g. ONNX Runtime → LiteRT), which the redact migration did. Higher risk;
  most of the sharp edges below come from this.

Read all of it, then follow §10 (order of operations).

---

## 0. Take stock of what exists

Before touching anything, inventory the three SDKs and answer:

- **Swift** (`<model>-swift`): does it already use `desert-ant-core`'s
  `InferenceSession` seam, `ModelStore`, `ModelDistribution`? Modern DAL Swift
  SDKs do; older ones may hand-roll Core ML + downloads. If it already uses the
  seam, it becomes the shared `Sources/<Model>` almost verbatim.
- **Kotlin** (`<model>-kotlin`): is it a *reimplementation* of the pipeline in
  Kotlin (e.g. ONNX Runtime + a Kotlin tokenizer/post-processor), or does it call
  a Swift native? The target is the latter — a thin Kotlin API over a JNI native
  built from the **same Swift pipeline**. If it's a Kotlin reimplementation, that
  code is **discarded** (the Swift core replaces it); you keep only the public
  Kotlin API shape and the Gradle/publish setup.
- **JS** (`<model>-js`): same question. Modern DAL JS SDKs are a thin host over a
  **Swift→wasm core** (`RedactWeb.wasm`) via `globalThis.__<Model>Host`; older
  ones reimplement in transformers.js/onnxruntime-web. If it's a reimplementation,
  the pipeline logic is discarded and replaced by the wasm core; you keep the
  public API shape.

**The unifying insight:** the goal is *one* pipeline (Swift), compiled natively
for Apple, to a `.so` for Android (via a C ABI + JNI), and to wasm for the web.
Any Kotlin/JS *pipeline* code is redundant and goes away; only the platform
*shells* (public API, packaging, JNI/JS host) survive, and those become the
`Sources/<Model>Android`, `Sources/<Model>Web`, `packages/<model>-kotlin`,
`packages/<model>-node` in the unified repo.

---

## 1. Choose the repo that becomes the monorepo

Make **`<model>-swift`** the new unified repo (rename it to `<model>` on GitHub,
or keep the name and just adopt the layout). It already has the SwiftPM package;
you add `packages/<model>-kotlin` and `packages/<model>-node` inside it. The old
`<model>-kotlin` and `<model>-js` repos get **archived** with a `README.md`:

```
# <model>-js has moved

This package has moved to the unified <Model> repository:

https://github.com/Desert-Ant-Labs/<model>
```

(That redirect is all the archived repos need; leave their history intact.)

The unified repo's target layout is in `author-cross-platform-swift-sdk.md` §2.
Move `<model>-kotlin`'s Gradle project into `packages/<model>-kotlin/` and
`<model>-js`'s package into `packages/<model>-node/`, then rework them per §4–§5
below.

---

## 2. The shared pipeline (mostly already exists)

`Sources/<Model>` comes from `<model>-swift`. If that SDK already used the
`InferenceSession` seam, the only pipeline changes are runtime/artifact plumbing
in `ModelLoading.swift` and `Model.swift` (§3). If it hand-rolled Core ML, first
refactor it onto the seam (see the authoring doc §1.1 / §3) — that refactor is
what makes Android and web free.

Confirm the pure-Swift, **no-Foundation-on-Android** rule holds (uses `Regex`,
`JSON`, `TextNormalization`, `RealModule`, not Foundation in the hot path). If
the Swift SDK imported Foundation for regex/JSON, swap to the core modules — this
is required for the Android build to stay small.

---

## 3. If you're also changing the non-Apple runtime (flavor B)

This is the ONNX-Runtime→LiteRT change redact made. The deltas:

### 3.1 Cut a `desert-ant-core` release with the new backend first
LiteRT lives in core behind `DAL_INFERENCE_LITERT` (default stays ORT). The
consuming SDK depends on a **tag**, so land the backend (and any fixes) in core
and **release a tag** (e.g. `0.2.x`) before pointing the SDK at it. During the
redact migration, core needed several follow-up fixes discovered only by wiring a
real model — budget for this:
- serialize `LiteRTSession.run` (fixed-buffer shim isn't reentrant) — core 0.2.1;
- `.auto` accelerator (GPU-when-bundled, CPU fallback) — 0.2.2;
- **own the from-bytes model buffer** (zero-copy `CreateModelFromBuffer`; the
  Android bundled path freed it → SIGSEGV) — 0.2.3;
- split `Package.swift` into typed `let`s (Xcode manifest type-check timeout that
  broke Apple) — 0.2.4.

Bump the SDK's core dependency to the tag that has all of them.

### 3.2 Re-export the model as `.tflite` and re-host
Add `<model>.tflite` (fixed-256, 2-input int32 `input_ids`/`attention_mask`,
baked positions, `logits` output, int8 dynamic quant) from the **same
checkpoint** that produced the existing `.onnx`/`.mlmodelc`. See
`author-cross-platform-swift-sdk.md` §6.3 and `redact-training/scripts/export_tflite.py`.
**Parity gate:** argmax 1.0000 + PSNR vs fp32 torch, and span-for-span vs the
existing `.onnx`/`.mlmodelc` on your deterministic corpus. Upload at a **new HF
model tag** (old tags keep the `.onnx` for older SDK versions) and bump
`<Model>.modelRevision`.

### 3.3 Replace ONNX with LiteRT in the SDK (don't keep both off-Apple)
- `ModelLoading.swift`: `<Model>Model.onnx` → `.tflite`; `artifact` returns
  `.tflite` off-Apple; the `.android/.linux/.windows/.web` distribution file
  lists become `[tflite] + sidecars`; both `.mlmodelc` and `.tflite` use the same
  fixed-window tensor layout (so drop any per-artifact `ModelLayout` enum — after
  the migration it's a single case and should be removed).
- `Model.swift`: the non-Apple path builds the tflite's exact inputs (2× int32
  `[1,256]`); remove the dynamic-sequence ONNX path.
- Resource target: `Sources/<Model>ONNXResources` → `Sources/<Model>TFLiteResources`
  (`<model>.tflite` + sidecars); update the accessor `enum` and the `Package.swift`
  product/target. Keep `<Model>CoreMLResources` untouched.
- Tests: update `#if canImport(CoreML)` else-branch imports from
  `<Model>ONNXResources` to `<Model>TFLiteResources`, and the bundled-model path
  from `<model>.onnx` to `<model>.tflite`.

### 3.4 Vendor `libLiteRt.so`, drop `libonnxruntime.so`
In `mise.toml`, `build-swift`/`test-swift` export `DAL_INFERENCE_LITERT=1` and
link `-LVendor/litert/lib/linux-x64` (fetched by a new `litert-libs` task from
the `ai-edge-litert` **2.1.6** pip wheel). `android-natives` vendors per-ABI
`libLiteRt.so` from the litert **2.1.6** Maven AAR instead of the onnxruntime
AAR, links `-LVendor/litert/lib/android-<arch>`, and copies `libLiteRt.so` (not
`libonnxruntime.so`) into `jniLibs`. See the authoring doc §7 + §10.

---

## 4. Android: reshape the Kotlin package

Move `<model>-kotlin` to `packages/<model>-kotlin/`. In the unified world:

- The **pipeline** is the Swift core compiled to `lib<Model>Android.so` (static
  stdlib) via `Sources/<Model>Android/{CABI,AndroidJNI}.swift`. Any Kotlin
  pipeline code from the old SDK is **deleted**.
- `src/main/kotlin/ai/desertant/<model>/<Model>Native.kt` — `external fun`
  declarations matching the `@_cdecl("Java_ai_desertant_<model>_<Model>Native_…")`
  entry points, plus `System.loadLibrary("LiteRt")` then
  `System.loadLibrary("<Model>Android")` (load the runtime first so the
  `DT_NEEDED libLiteRt.so` resolves).
- `src/main/kotlin/ai/desertant/<model>/<Model>.kt` — the public Kotlin API
  (keep its shape from the old SDK): a `bundled()` that reads the model bytes
  from the optional resources module and calls `<Model>Native.createBundled(...)`,
  and a `constructor(context)` that downloads on demand.
- `src/main/kotlin/ai/desertant/core/HostBridge.kt` — **vendored verbatim** from
  `desert-ant-core/kotlin/HostBridge.kt` (regex/JSON/HTTP callbacks the Swift
  core calls back into via `CHostBridge`). Do not edit here.
- Rename the optional bundled-model module: `<model>-onnx-resources` →
  `<model>-tflite-resources` (coordinates `ai.desertant:<model>-tflite-resources`),
  update `settings.gradle.kts`, `swift-android.gradle.kts` output dirs, the
  jar-check file list (`<model>.tflite`, tokenizer, labels), and the base-AAR
  "ships no model" cleanup.
- The **base AAR ships no model** (downloads on demand); bundling is opt-in via
  the resources module.

**`RedactTest.kt`** (instrumented) runs the bundled path; assert identical
redactions. Run it on a **real device / x86_64 KVM emulator / Firebase**, not the
Apple-Silicon arm64 emulator (XNNPACK SME crash — authoring doc §8).

If the old Kotlin SDK published to **JitPack**, note the switch to **Maven
Central** (`publish-android`, vanniktech plugin) — the AAR contains a prebuilt
Swift native, which JitPack (source builds) can't produce.

---

## 5. Web: reshape the npm package

Move `<model>-js` to `packages/<model>-node/`. The pipeline is the Swift core
compiled to `<Model>Web.wasm` (`Sources/<Model>Web/main.swift`, `#if os(WASI)`),
which installs `globalThis.__<Model>Exports {load, <run>}`. `index.js` is the
**host**: it installs `globalThis.__<Model>Host` and exposes the public class.

If migrating from a transformers.js/onnxruntime-web JS reimplementation, that
whole implementation is **replaced** by the wasm core + a runtime host:

- `index.js` `createSession(modelSource)` / `run(inputs)` implement the generic
  tensor contract (`{ name: { data: Uint8Array, dims, type } }`) over the chosen
  runtime. For LiteRT, that runtime is **LiteRT.js** (`@litertjs/core`): load it
  once (`loadLiteRt(wasmDir)`), `loadAndCompile(modelBytes, { accelerator })`,
  build `new Tensor(typedArray, shape)`, `model.run({name: tensor})` → outputs,
  delete tensors (manual memory management). Int32 in, float32 `logits` out.
- `package.json`: peerDependency `@litertjs/core` (optional), swap the old
  `onnxruntime-*`/`transformers` deps out; `files: [index.js, index.d.ts, dist,
  LICENSE.md]`.
- Node vs browser: LiteRT.js is a **browser** runtime (needs a DOM), so the Node
  test **gracefully skips** and a headless-Chromium test validates the real path.
  Update `test/<model>.test.mjs` to load resources from
  `Sources/<Model>TFLiteResources/Resources` and keep the graceful skip.

`mise run build-web` produces `dist/`; the Swift wasm core is unchanged by the
runtime swap (only the JS host + downloaded artifact change).

---

## 6. Versioning across the merge

The unified repo single-sources the version from
`packages/<model>-node/package.json`; `mise run set-version X.Y.Z` propagates to
the two Gradle modules and the README (SwiftPM `from:` **and** the Maven
snippets — make sure `set-version` rewrites the `ai.desertant:<model>[-tflite-resources]:X.Y.Z`
lines too; redact's originally missed them). Pick a version **above** the highest
previously published across the three old SDKs (redact was at 0.3.1 across the
old repos → the unified LiteRT release was **0.4.0**).

---

## 7. Update every reference to point at the one repo

After publishing, the three-repo links are stale everywhere. Update:

- **HF model card** (`desert-ant-labs/<model>` `README.md`): "Try it" section →
  one repo; runtime/size text → the new runtime; files table → `.tflite`; drop
  `.onnx` from the repo `main` (old tags keep it).
- **HF org card** — the `desert-ant-labs/README` **Space** (`README.md`): the
  `<Model>` row's iOS/Android/Web links → `github.com/Desert-Ant-Labs/<model>`.
- **GitHub org profile** — `Desert-Ant-Labs/.github` `profile/README.md`: same
  row change (edit via the GitHub API: get contents+sha, PUT the new base64).
- **Website** (`website` repo): the model catalog. redact's website is
  data-driven — set `repo: "<model>"` on the model in `data/models.json` (a
  `repoUrl` override in `build/templates.mjs` **and** `build/build.mjs` makes all
  platform links, `catalog.json`, and `llms.txt` point at the one repo); update
  install snippets and the `oneLiners`/facts. The website **i18n gate** blocks
  the build on any changed English string — refresh those keys in every
  `data/i18n/<locale>.json` (`t` = translation, `src` = `sha1(newEnglish)[:10]`).
- **Both demos** — HF Space + website widget — to the new SDK/runtime (see the
  authoring doc §13; esm.sh/CDN can't serve the wasm-core SDK, so self-host).
- The unified repo's own `README.md` (all three platforms, one repo, correct
  versions).

---

## 8. Archive the old repos

Set `redact-js` / `redact-kotlin` (etc.) to **public, archived** on GitHub with
the "has moved" `README.md` (§1). Their old published packages (JitPack/npm) and
old GitHub tags stay as-is for existing consumers; only new work happens in the
unified repo.

---

## 9. Migration-specific pitfalls (learned on redact)

Everything in `author-cross-platform-swift-sdk.md` §11 applies, plus these that
are specific to *migrating*:

1. **Cut the core release first.** The SDK can't ship pinned to core `main`; and
   wiring a real model into a new core backend surfaces bugs (§3.1) that each
   need their own core tag.
2. **`.onnx` is still referenced by old model tags.** Removing it from HF `main`
   is fine (SDK pins a new tag), but don't delete old tags — old SDK versions
   download from them.
3. **The old Kotlin/JS pipeline code is a trap.** It looks reusable but it's a
   parallel reimplementation; keeping it means two sources of truth. Delete it;
   the Swift core is canonical.
4. **Don't keep both runtimes off-Apple.** Replacing (not dual-shipping) ONNX
   with LiteRT keeps the matrix small; only Apple stays different (Core ML).
5. **Watch the "works on Linux, crashes on Android" trap** — that's almost
   always the from-bytes buffer-ownership bug (authoring doc §7.3), *not* the
   emulator. The emulator XNNPACK/SME crash (§8) is separate; distinguish them by
   the crash signature (`SEGV_MAPERR` in `LiteRtRunCompiledModel` = buffer;
   `SIGILL` at `rdsvl` = SME/emulator).
6. **jj/git history when force-moving `main`.** If you rewrite a commit that was
   already pushed (e.g. an accidental `jj describe` on a published change),
   rebuild clean history so the release tag's commit stays in `main`'s ancestry
   before pushing — don't leave the tagged commit detached.
7. **`git ls-files` can look stale under jj** — jj's working copy holds the
   deletions/renames; they apply on push. Verify with `jj diff -r @`.
8. **The website auto-deploys on commit** (Cloudflare Pages); the HF Space
   rebuilds on upload. So a bad push goes live — build + test locally first
   (`npm run build && npm test`, and a headless-browser demo check).

---

## 10. Order of operations

1. **core**: land the new backend/fixes in `desert-ant-core`; **cut a tagged
   release** (do the full 0.2.1→0.2.4 sequence if you hit the redact bugs).
2. **export + host**: `<model>.tflite` from the same checkpoint; parity gate;
   upload at a new HF model tag; note it for `modelRevision`.
3. **`<model>-swift` → unified repo**: bump core dep to the tag; do the
   `ModelLoading`/`Model`/resources/`Package.swift` changes (§3.3, and the
   authoring doc §5 typed-`let` split); **get macOS `swift test` (Core ML) and
   Linux `mise run test-swift` (LiteRT) green** — this proves the shared core on
   both real backends before touching Android/web.
4. **web**: reshape `packages/<model>-node` (LiteRT.js host); `mise run
   build-web`; validate in headless Chromium.
5. **android**: reshape `packages/<model>-kotlin` (rename resources module, JNI
   bundled path, Gradle); `mise run android-natives`; instrumented test on real
   hardware / x86_64 KVM emulator.
6. **cleanup**: remove all `.onnx`/old-runtime references across the repo (grep
   `onnx`, `-swift`/`-kotlin`/`-js`); clean local `Vendor/onnxruntime` and stale
   `packages/<model>-kotlin/build`.
7. **version + publish**: `set-version X.Y.Z` (above the old max), push `main`,
   `publish-swift` → `publish-web` → `publish-android`. Verify the published AAR
   contains only LiteRT `.so`s (no `libonnxruntime.so`).
8. **references**: model card, org card (`desert-ant-labs/README` Space), GitHub
   org profile, website catalog (+ i18n), both demos, unified README — all → one
   repo/new runtime.
9. **archive** the old `-kotlin`/`-js` repos with "has moved" READMEs.

---

## 11. Definition of done (migration)

- One repo `Desert-Ant-Labs/<model>` builds/tests/publishes all three platforms;
  `<model>-kotlin`/`-js` archived and redirecting.
- All four surfaces green (macOS Core ML, Linux LiteRT, web browser E2E, Android
  on real hardware); identical outputs; span-for-span parity vs the pre-migration
  artifacts.
- Published at one version (npm + Maven Central + SwiftPM tag/GH release); HF
  model at a new tag with `modelRevision` pinned; no ONNX left in the repo, the
  AAR, or HF `main`.
- Every reference points at the one repo: model card, org card, GitHub org
  profile, website catalog, both demos.
