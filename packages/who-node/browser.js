// On-device speaker diarization for JavaScript: the universal entry. It runs
// in the browser and, via the `#platform` seam, server-side in Node (e.g. an
// SSR pass), on WebAssembly + LiteRT.js. For the prebuilt native server core,
// import `@desert-ant-labs/who/native`.
//
// Node-only code lives behind `#platform`, which bundlers resolve by condition
// (browser -> platform-browser.js, otherwise platform-node.js), so this file
// never references `node:*`.
import * as platform from "#platform";
import { createWasmSdk } from "@desert-ant-labs/core";
import { PACKAGE_NAME } from "./codec.js";
import { makeWho } from "./who.js";

// The wasm core instantiates at import time (top-level await); the model is only
// wired in Who.load(). The CPU by default: the graphs are not measured on WebGPU
// yet, so `accelerator: "auto"` is the caller's choice.
export const Who = makeWho(await createWasmSdk({
  platform,
  packageName: PACKAGE_NAME,
  defaultAccelerator: "wasm",
}), platform.decodeAudio);

export { Diarization, Turn } from "./diarization.js";
