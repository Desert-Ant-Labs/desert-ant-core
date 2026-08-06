# Shared model-SDK build catalog

`model-sdk.toml` is the shared mise task catalog for the Desert Ant Labs model
SDKs (shapes, emo, redact, ...). The identical build/publish/version logic lives
here once; a consumer includes it and supplies a few `[vars]` instead of copying
~500 lines of `mise.toml`.

**In this monorepo**, the catalog is included from `mise.model.toml` behind
`MISE_ENV=model`, and the model is chosen at run time rather than by `[vars]`:

```sh
MISE_ENV=model DAL_MODEL=redact DAL_PRODUCT=Redact mise run build
```

Every build task is scoped to that model: `build-swift` builds its target alone,
and the rest write only into `packages/<model>-{node,kotlin}`.

Every artifact in the repo ships one version. `mise run set-version X.Y.Z` sets
it everywhere (core, every model package, each `Catalog.swift`), the model
packages pin `@desert-ant-labs/core` exactly, and `mise run check-version` fails
if anything disagrees. One `vX.Y.Z` tag then publishes all of it.

**In a standalone model repo**, `[vars]` names the one model, as below.

## Using it from a model repo

```toml
# <model>/mise.toml
[tools]
swift = "6.3.3"

[vars]
model        = "emo"        # lowercase: paths + npm/Maven/HF/GitHub coordinates
product      = "Emo"        # capitalized: Swift products, native lib names

[env]
DAL_GPU = ""                # non-empty ships Linux LiteRT GPU siblings

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

## What the catalog owns

`build`, `build-swift`, `build-android`, `build-web`, `node-natives`,
`litert-libs` (internal), `android-natives` (internal), `test-swift`,
`test-android`, `test-bundles`, `set-version`, `check-version`,
`publish-swift`, `publish-android`, `publish-web`.

`test-bundles` is the bundle matrix: it packs `packages/<model>-node` with
`npm pack` and builds it with esbuild, vite, webpack, and Next (Turbopack +
webpack), covering the browser, SSR-in-Node, and native server graphs. The npm
package is isomorphic and those graphs only exist inside a bundler, so this is
the only check that catches an SSR break before a consumer does. The harness
ships in `@desert-ant-labs/core` as the `dal-bundle-matrix` bin and runs at the
core version the package depends on. See
[js/test/bundle/README.md](../js/test/bundle/README.md).

Everything model-specific is derived from `model` / `product`. The catalog
assumes the standard SDK layout: `packages/<model>-kotlin`, `packages/<model>-node`
(npm version is the single source of truth), and `Desert-Ant-Labs/<model>` /
`ai.desertant:<model>` / `@desert-ant-labs/<model>` coordinates. No SDK ships a
model artifact - every platform downloads the revision pinned in the core model
catalog - so there is nothing to stage into a build.

## Building a model SDK (CI)

Every SDK repo verifies it compiles on all its platforms via a second shared
reusable workflow, so a broken build is caught on the PR rather than at release:

```yaml
# <model>/.github/workflows/build.yml
name: Build
on:
  push:
    branches: [main]
  pull_request:
jobs:
  build:
    uses: Desert-Ant-Labs/desert-ant-core/.github/workflows/model-sdk-build.yml@v0.5.5
```

Jobs: `swift-apple`, `swift-linux`, `android` (natives + AAR), `wasm`, and
`node-native` on both host OSes. Build-only - no credentials, nothing published.

## Releasing a model SDK

Releases are tag-driven and shared: every SDK repo calls one reusable workflow,
`.github/workflows/model-sdk-release.yml` in this repo, so the pipeline is
defined once.

```yaml
# <model>/.github/workflows/release.yml  - the whole thing
name: Release
on:
  push:
    tags: ["v*"]
  workflow_dispatch:        # dry-runs the build paths without publishing
jobs:
  release:
    uses: Desert-Ant-Labs/desert-ant-core/.github/workflows/model-sdk-release.yml@v0.4.3
    secrets: inherit
```

`mise run set-version X.Y.Z`, commit, push `vX.Y.Z`, and it publishes only what
changed since the previous tag (a pure version bump counts as no change):

| Artifact | Ships when |
|---|---|
| GitHub Release (the SwiftPM release) | always - the tag *is* the release |
| `ai.desertant:<model>` | `Sources/` or `packages/<model>-kotlin/` changed |
| `@desert-ant-labs/<model>` | `Sources/` or `packages/<model>-node/` changed |

The npm job builds the prebuilt native core for linux-x64, linux-arm64, and
darwin-arm64 in a matrix and gathers them into the tarball, replacing the manual
per-platform build. Credentials are organization secrets, so a new SDK repo needs
no secret setup - just the caller workflow above.

## Versioning

The catalog rides desert-ant-core's own `vX.Y.Z` release tags: pin `includes` to
a semver tag. It lives in `sdk-build/` (not `mise-tasks/`) so mise does not
auto-load it into desert-ant-core's own task set. Change the catalog, cut a new
core release (a version-only bump publishes nothing, since the publish gates
skip unchanged artifacts), and bump each model repo's `includes` ref to the new
tag. Included tasks shadow same-named local tasks, so keep the catalog fully
parameterized; for a genuinely model-specific need, define a distinctly-named
local task or branch on a var/`DAL_*` env inside the shared task.
