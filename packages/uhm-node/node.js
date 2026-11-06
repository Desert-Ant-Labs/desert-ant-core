// The `node` conditional-exports entry: the same Uhm API as browser.js, run
// through the prebuilt Swift core instead of WebAssembly. The koffi harness
// lives in @desert-ant-labs/core/node; the public API is `uhm.js`.
import { fileURLToPath } from "node:url";
import path from "node:path";
import { createNativeSdk } from "@desert-ant-labs/core/node";
import { MODEL_ID, PACKAGE_NAME, BIAS, SAMPLE_RATE } from "./codec.js";
import { makeUhm } from "./uhm.js";
export { DesertAnt } from "@desert-ant-labs/core/node";

export { BIAS, SAMPLE_RATE };

const HERE = path.dirname(fileURLToPath(import.meta.url));

export const Uhm = makeUhm(createNativeSdk({
  here: HERE,
  packageName: PACKAGE_NAME,
  modelId: MODEL_ID,
  coreName: "UhmNode",
}));
