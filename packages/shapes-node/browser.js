// On-device shape recognition for JavaScript: the universal entry. It runs in
// the browser and, via the `#platform` seam, server-side in Node (e.g. an SSR
// pass), on WebAssembly + LiteRT.js. For the prebuilt native server core,
// import `@desert-ant-labs/shapes/native`.
//
// Node-only code lives behind `#platform`, which bundlers resolve by condition
// (browser -> platform-browser.js, otherwise platform-node.js), so this file
// never references `node:*`.
import * as platform from "#platform";
import { createWasmSdk } from "@desert-ant-labs/core";
import { PACKAGE_NAME } from "./codec.js";
import { makeShapes } from "./shapes.js";

// The wasm core instantiates at import time (top-level await); the model is only
// wired in Shapes.load().
export const Shapes = makeShapes(await createWasmSdk({
  platform,
  packageName: PACKAGE_NAME,
}));
