# Shared model-SDK build catalog

`model-sdk.toml` is the shared mise task catalog for the Desert Ant Labs model
SDKs (shapes, emo, redact, ...). The identical build/publish/version logic lives
here once; each model repo includes it from a pinned tag and supplies a few
`[vars]` instead of copying ~500 lines of `mise.toml`.

## Using it from a model repo

```toml
# <model>/mise.toml
[tools]
swift = "6.3.3"

[vars]
model        = "emo"        # lowercase: paths + npm/Maven/HF/GitHub coordinates
product      = "Emo"        # capitalized: Swift products, native lib names
tflite_files = "emo.tflite emo_meta.json emo_tokenizer.bin"  # staged into the AAR resources

[env]
DAL_GPU = ""                # non-empty ships the LiteRT GPU accelerator siblings

[task_config]
includes = ["git::https://github.com/Desert-Ant-Labs/desert-ant-core.git//sdk-build/model-sdk.toml?ref=v0.4.0"]

# Test harnesses differ per model, so the test aggregate + web/node tests stay
# local. test-swift and test-android come from the catalog.
[tasks.test]
depends = ["test-swift", "test-web", "test-android"]

[tasks.test-web]
dir = "{{ config_root }}/packages/emo-node"
tools = { node = "22" }
run = "npm test"
```

An optional `RELEASE_HIGHLIGHTS.md` at the repo root is appended to the
`publish-swift` GitHub release notes.

## What the catalog owns

`build`, `build-swift`, `build-android`, `build-web`, `node-natives`,
`litert-libs` (internal), `android-natives` (internal), `test-swift`,
`test-android`, `set-version`, `check-version`, `publish-swift`,
`publish-android`, `publish-web`.

Everything model-specific is derived from `model` / `product` / `tflite_files`.
The catalog assumes the standard SDK layout: `packages/<model>-kotlin` (+ a
`<model>-tflite-resources` Gradle module), `packages/<model>-node` (npm version
is the single source of truth), `Sources/<Product>TFLiteResources/Resources`,
and `Desert-Ant-Labs/<model>` / `ai.desertant:<model>` / `@desert-ant-labs/<model>`
coordinates.

## Versioning

The catalog rides desert-ant-core's own `vX.Y.Z` release tags: pin `includes` to
a semver tag. It lives in `sdk-build/` (not `mise-tasks/`) so mise does not
auto-load it into desert-ant-core's own task set. Change the catalog, cut a new
core release (a version-only bump publishes nothing, since the publish gates
skip unchanged artifacts), and bump each model repo's `includes` ref to the new
tag. Included tasks shadow same-named local tasks, so keep the catalog fully
parameterized; for a genuinely model-specific need, define a distinctly-named
local task or branch on a var/`DAL_*` env inside the shared task.
