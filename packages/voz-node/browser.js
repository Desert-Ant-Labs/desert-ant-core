// On-device speech recognition for JavaScript: the universal entry. It runs in
// the browser on WebAssembly + ONNX Runtime Web (the encoder on WebGPU, the
// decode step on WebNN where the browser has it) and, via the platform seam,
// server-side in Node on the same core.
//
// The public API is `voz.js`; `#platform` is the only thing that differs
// between the two, and bundlers resolve it by condition (browser ->
// platform-browser.js, otherwise platform-node.js), so this file never
// references `node:*`.
//
// Nothing instantiates at import time, unlike the LiteRT models' entries: this
// core is a large module and its weights are 1.19 GB resident, so a page that
// imports `Voz` without calling `Voz.load()` pays nothing.
import * as platform from "#platform";
import { makeVoz } from "./voz.js";

export { SAMPLE_RATE } from "./codec.js";

export const Voz = makeVoz(platform);
