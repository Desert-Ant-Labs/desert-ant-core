# @desert-ant-labs/redact

On-device multilingual PII redaction for JavaScript. Finds names, addresses,
emails, phone numbers, cards, IBANs, national IDs and more across the 24 official
EU languages, fully locally.

Two entries share one `Redact` API:

- **`@desert-ant-labs/redact`** (default): a WebAssembly pipeline with
  [LiteRT.js](https://www.npmjs.com/package/@litertjs/core) inference
  (XNNPACK-accelerated CPU by default, optional WebGPU), for the **browser**. It
  has no native dependencies, so a single import builds cleanly for every target
  of a multi-target bundler (Next.js, Remix, SvelteKit, Nuxt), including the
  browser bundle and the Client-Component SSR pass those frameworks render in
  Node. It is safe to *import* during server-side rendering, but LiteRT.js needs
  a browser (or Web Worker) to initialize, so `Redact.load()` runs inference only
  in the browser; calling it in plain Node throws an actionable error pointing
  you to `/native`.
- **`@desert-ant-labs/redact/native`**: a prebuilt native core (LiteRT on Linux,
  Core ML on macOS), for **server-side inference** in Node. No `@litertjs/core`,
  no build tools, no flags. Import it from server-only code (API routes, server
  actions, plain Node scripts). Do not import it from a component that also
  renders in the browser.

```bash
# Browser (default entry):
npm i @desert-ant-labs/redact @litertjs/core

# Server-side inference in Node (/native entry) needs no extra install:
npm i @desert-ant-labs/redact
```

```js
import { Redact } from "@desert-ant-labs/redact";

const redact = await Redact.load();            // downloads the model from HF at the pinned tag, cached
const r = await redact.redaction("Email Anna at anna@example.com.");

r.redactedText;      // "Email [GIVEN_NAME_1] at [EMAIL_1]."
r.items;             // detections: label, original, placeholder, confidence, offsets
const reply = await llm(r.redactedText);       // the LLM sees only placeholders
r.restore(reply);    // originals filled back in

redact.dispose();    // frees native resources in the /native build; no-op otherwise
```

Server-only code that wants the native core imports the same API from the
`/native` subpath:

```js
import { Redact } from "@desert-ant-labs/redact/native"; // server only
```

`Redact.load()` accepts:

- `directory`: an explicit model directory to self-host / run offline (native
  build, or the browser build under Node); files already there are used without a
  download, otherwise the model is downloaded into it. Omit for the managed cache
  (`~/.cache/desert-ant-models/...`).
- `modelBaseUrl` (browser build): a base URL you serve the model files from (e.g.
  `"/assets/redact/"`), loaded instead of the Hub for self-host / offline setups.
- `cacheRoot`: base directory for the managed on-disk cache (default `~/.cache`;
  native build, or the browser build under Node).
- `onProgress`: download progress callback, fraction in `[0, 1]`.
- `litert` (browser): bring-your-own LiteRT.js module (the `@litertjs/core`
  namespace, e.g. a bundler-managed import).
- `litertWasmDir` (browser): URL/path to the LiteRT.js Wasm files (defaults to
  the installed package, or the jsDelivr CDN in the browser).
- `accelerator` (browser): `"wasm"` (XNNPACK CPU, default), `"webgpu"`, or
  `"webnn"`.

By default the model is **downloaded from the Hugging Face Hub on first use** (at
the revision pinned to this package version), SHA-256 verified, and cached for
later runs, so nothing model-sized ships in the npm tarball. In Node the cache is
the OS cache dir; in the browser it is the fetch cache. Use `directory` (Node) or
`modelBaseUrl` (browser) to self-host / run fully offline. `@litertjs/core` is an
optional peer dependency (browser builds only).

## Bundlers and SSR

The default `@desert-ant-labs/redact` import is safe to use directly in
components: it is pure JavaScript + WebAssembly with no native modules, so
bundlers can build it for the browser and for the Node SSR pass from the same
module graph with no configuration.

The `@desert-ant-labs/redact/native` subpath loads a native addon (via `koffi`)
and is for server-only code. If you import it inside a framework that bundles
server code (for example a Next.js Route Handler or Server Action), mark it
external so the bundler does not try to bundle the native binary. In Next.js:

```js
// next.config.js
module.exports = { serverExternalPackages: ["@desert-ant-labs/redact"] };
```

The native server build ships for linux-x64, linux-arm64 (LiteRT), and
darwin-arm64 (Core ML). Other platforms fall back to a clear error at `load()`;
use the default WebAssembly build, the Swift package, or a browser for those.

The same model ships as a Swift package (iOS/macOS) and an Android AAR from the
same repository: https://github.com/Desert-Ant-Labs/redact

## License

[Desert Ant Labs Source-Available License 1.0](./LICENSE.md): free below
100,000 monthly active devices per platform; above that a commercial license is
required (licensing@desertant.com). Full terms: https://license.desertant.com/1.0
