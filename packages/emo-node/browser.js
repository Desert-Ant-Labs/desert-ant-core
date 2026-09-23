// On-device emoji suggestion for JavaScript: the universal entry. It runs in
// the browser and, via the `#platform` seam, server-side in Node (e.g. an SSR
// pass), on WebAssembly + LiteRT.js. For the prebuilt native server core,
// import `@desert-ant-labs/emo/native`.
//
// Node-only code lives behind `#platform`, which bundlers resolve by condition
// (browser -> platform-browser.js, otherwise platform-node.js), so this file
// never references `node:*`.
import * as platform from "#platform";
import { createWasmSdk } from "@desert-ant-labs/core";
import { PACKAGE_NAME } from "./codec.js";
import { makeEmo } from "./emo.js";

// The wasm core instantiates at import time (top-level await); the model is only
// wired in Emo.load().
export const Emo = makeEmo(await createWasmSdk({
  platform,
  packageName: PACKAGE_NAME,
}));
