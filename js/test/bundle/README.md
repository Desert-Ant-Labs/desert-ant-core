# The bundle matrix

`node test/bundle/run.mjs` (or `mise run test-bundles`) builds every model
package the way our consumers build it, with the real bundlers, and fails if any
target breaks.

## Why

The model packages are isomorphic: one import, four module graphs (browser,
SSR-in-Node, plain Node native, and each bundler's idea of the first three). The
seams that keep those graphs apart - the `browser` export condition, the
`#platform` imports condition, the split between `@desert-ant-labs/core` and its
`/node` and `/platform-node` entries - are invisible to unit tests, because
nothing enforces them until a bundler resolves them.

Every SSR break we have shipped worked fine under `node --test` and failed in a
consumer's `next build`. The 0.10.2 one:

```
./node_modules/koffi/index.js
non-ecmascript placeable asset
asset is not placeable in ESM chunks, so it doesn't have a module id
```

a bundler tracing a lazy `require("koffi")` and refusing to put a native addon
in an ESM chunk. Only running the bundler catches that class of bug, so we run
the bundlers.

## What it does

1. Stages each `packages/<model>-node` and, in this repo, `js/`, then packs them
   with `npm pack`. Every scenario consumes the **tarball**, so a missing
   `files` or `exports` entry fails here rather than in a consumer's install.
2. Installs the tarballs once into a temp workspace next to the bundlers.
3. Runs the scenario matrix, reporting every failure instead of stopping at the
   first.

`dist/` (the wasm core) comes from `mise run build-web`. When it exists the
matrix uses the real one; otherwise it stages a stub with the same module shape,
so the matrix also runs on a machine with no Swift toolchain. CI does both: the
fast JS job runs it with stubs, the wasm job runs it right after `build-web`
with the real artifacts.

## The matrix

| scenario | what a consumer is doing |
| --- | --- |
| `node-ssr-import` | a framework's SSR pass imports the universal entry in plain Node |
| `node-native-import` | server-side code imports `<pkg>/native` (the koffi path) |
| `esbuild-browser` | esbuild bundles the universal entry for the browser |
| `esbuild-node` | esbuild bundles it for a Node/SSR target, with nothing external |
| `vite-browser` | vite/rollup builds a browser app |
| `webpack-web` | webpack builds a browser app (`target: web`) |
| `next-turbopack` | Next App Router, a **client component** importing the model, built with Turbopack |
| `next-webpack` | the same app, built with webpack |
| `next-native-route` | Next route handler on `/native`, with `serverExternalPackages: ["koffi"]` |

The two client-component scenarios are the 0.10.2 repro, and they run with a
stock `next.config` on purpose: adding `serverExternalPackages` there would make
the build pass by configuration and hide the regression they exist to catch.
Only the server-route scenario declares koffi external, because that is the
documented configuration for server-side use, so building it keeps the docs
honest.

Bundling scenarios assert on the output as well as the exit status: a browser
bundle must contain no `koffi` and no `node:` builtin specifier, and it must
contain the model's host global (otherwise a build that tree-shook the package
away would pass while testing nothing).

## Running it

```bash
mise run test-bundles                              # everything
node test/bundle/run.mjs --list
node test/bundle/run.mjs --only next-turbopack     # one scenario
node test/bundle/run.mjs --skip next-webpack --keep  # keep the temp workspace
```

Roughly 45s end to end, most of it the two Next builds. It needs network for the
one `npm install`.

In a model SDK repo there is no `js/`, so the harness ships in the core tarball
as a bin:

```bash
npx --yes --package @desert-ant-labs/core@<version> dal-bundle-matrix
```

which is what that repo's `mise run test-bundles` does. There, the package's own
declared `@desert-ant-labs/core` dependency installs from npm, so the matrix
tests the model package against the core its users actually get.

## Adding a scenario

Append to `scenarios` in `run.mjs`: a `name`, a one-line `what` describing the
consumer situation (not the mechanism), and a `run({ work, pkgs, bin })` that
throws on failure. `mkApp` writes a throwaway app importing every model package,
`bin("vite")` resolves a bundler from the shared install, and
`assertBrowserClean` covers the standard browser-output assertions.

A new scenario is worth adding whenever a consumer reports a build failure we
did not catch: reproduce it here first, then fix it.
