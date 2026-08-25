// On-device spoken language identification for JavaScript: the universal entry.
// It runs in the browser and, via the platform seam, server-side in Node (the
// Client-Component SSR pass frameworks render in Node), both on the same
// WebAssembly + @litertjs/core (LiteRT.js) pipeline.
//
// There is nothing model-specific left in the wiring: @desert-ant-labs/core owns
// the LiteRT.js session, the Hub download, and the `modelBaseUrl` opt-out, and
// the public API is `ear.js` (shared with the native entry). For a prebuilt
// native server core (no @litertjs/core, best server throughput), import
// `@desert-ant-labs/ear/native`.
//
// All node-only code lives behind the `#platform` import, which bundlers resolve
// at build time by condition (browser -> platform-browser.js, otherwise
// platform-node.js), so this file never references `node:*`.
import * as platform from "#platform";
import { createWasmSdk } from "@desert-ant-labs/core";
import { PACKAGE_NAME, SAMPLE_RATE } from "./codec.js";
import { makeEar } from "./ear.js";

export { SAMPLE_RATE };

// The wasm core instantiates at import time (top-level await); the model is only
// wired in Ear.load().
export const Ear = makeEar(await createWasmSdk({
  platform,
  packageName: PACKAGE_NAME,
}));
