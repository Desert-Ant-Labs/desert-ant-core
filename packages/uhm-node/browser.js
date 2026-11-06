// On-device filler-word detection for JavaScript: the universal entry.
// It runs in the browser and, via the `#platform` seam, server-side in Node
// (e.g. an SSR pass), on WebAssembly + LiteRT.js. For the prebuilt native
// server core, import `@desert-ant-labs/uhm/native`.
//
// Node-only code lives behind `#platform`, which bundlers resolve by condition
// (browser -> platform-browser.js, otherwise platform-node.js), so this file
// never references `node:*`.
import * as platform from "#platform";
import { createWasmSdk } from "@desert-ant-labs/core";
import { PACKAGE_NAME, BIAS, SAMPLE_RATE } from "./codec.js";
import { makeUhm } from "./uhm.js";
export { DesertAnt } from "@desert-ant-labs/core";

export { BIAS, SAMPLE_RATE };

// The wasm core instantiates at import time (top-level await); the model is only
// wired in Uhm.load().
export const Uhm = makeUhm(await createWasmSdk({
  platform,
  packageName: PACKAGE_NAME,
}));
