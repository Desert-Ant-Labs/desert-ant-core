# Browser inference

`mise run test:browser` runs every model's real browser path in headless
Chromium: the Swift → WebAssembly core plus LiteRT.js, on weights downloaded
from the Hub, through the package's default entry.

## Why

The browser is the **default** entry of every model package
(`import { Emo } from "@desert-ant-labs/emo"`), and until this existed it was
the one shipped platform nothing executed:

- `test:bundles` proves the package *builds* for a browser in esbuild, vite,
  webpack, and Next. A bundle that compiles can still fail to instantiate.
- `test:wasi` runs the Swift core under wasm, but the model-backed tests are
  `#if !os(WASI)`, so no weights are ever loaded there.
- `test:node` runs the native core, which is a different backend entirely.

So a break in WebAssembly instantiation, the LiteRT.js session, the Hub download
in a browser, or the browser side of the `#platform` split would have reached
consumers. Now it fails here.

## How it works

One harness, no per-model logic:

1. Serves the repo over HTTP, including `node_modules`, so the page gets the
   **local** `@desert-ant-labs/core` through the workspace symlink rather than a
   published copy.
2. Builds each page's import map from real Node resolution
   (`createRequire(...).resolve`), so it follows npm's hoisting instead of
   hardcoding a layout. It also maps `#platform` explicitly, which an import map
   has to do because that condition is package-internal.
3. Imports `packages/<model>-node/test/browser-case.js` in the page and runs it.
4. Reads the result back out and calls the case's own `check()` in Node.

One page per model, so two models' `#platform` mappings can never collide.

## Adding a model

Add `packages/<model>-node/test/browser-case.js`. Nothing in the harness
changes.

```js
export async function run({ Model }, { litert, litertWasmDir }) {
  const model = await Model.load({ litert, litertWasmDir });
  try {
    return { /* anything structured-cloneable */ };
  } finally {
    model.dispose();
  }
}

export function check(result) {
  if (!ok(result)) throw new Error("...");
}
```

`run` executes in the browser, so it may only return values the page can
structured-clone. `check` runs in Node. Assert the same behaviour the Swift and
Kotlin suites assert, so "works in the browser" means the same thing it means
everywhere else.

## Running it

```bash
mise run build:wasm            # required: a stub dist cannot infer
mise run test:browser
mise run test:browser emo
mise run test:browser --headed # watch it
```

Chromium is fetched on demand on first run. The model download needs network;
`DAL_BROWSER_TIMEOUT_MS` (default 300000) covers a cold one.
