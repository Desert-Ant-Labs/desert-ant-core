// On-device gistji suggestion for JavaScript: the universal entry. It runs in the
// browser and, via the platform seam, server-side in Node (the Client-Component
// SSR pass frameworks render in Node), both on the same WebAssembly +
// @litertjs/core (LiteRT.js) pipeline: XNNPACK-accelerated CPU ("wasm") by
// default, with optional WebGPU in the browser.
//
// There is nothing model-specific left in the wiring: @desert-ant-labs/core owns
// the LiteRT.js session, the Hub download, and the `modelBaseUrl` opt-out, and
// the public API is `gist.js` (shared with the native entry). For a prebuilt
// native server core (no @litertjs/core, best server throughput), import
// `@desert-ant-labs/gist/native`.
//
// All node-only code lives behind the `#platform` import, which bundlers resolve
// at build time by condition (browser -> platform-browser.js, otherwise
// platform-node.js), so this file never references `node:*` and one import
// builds cleanly for every target of a multi-target bundler.
import * as platform from "#platform";
import { createWasmSdk } from "@desert-ant-labs/core";
import { PACKAGE_NAME } from "./codec.js";
import { makeGist } from "./gist.js";

// The wasm core instantiates at import time (top-level await); the model is only
// wired in Gist.load().
export const Gist = makeGist(await createWasmSdk({
  platform,
  packageName: PACKAGE_NAME,
}));

// The channel roll-up is pure JS over scores this package already returns - no
// model, no core - so both entries re-export the one implementation.
export { channelTopics } from "./channel.js";
