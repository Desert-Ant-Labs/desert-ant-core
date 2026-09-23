// The `node` conditional-exports entry: the same Ear API as browser.js, run
// through the prebuilt Swift core instead of WebAssembly. The koffi harness
// lives in @desert-ant-labs/core/node; the public API is `ear.js`.
import { fileURLToPath } from "node:url";
import path from "node:path";
import { createNativeSdk } from "@desert-ant-labs/core/node";
import { MODEL_ID, PACKAGE_NAME, SAMPLE_RATE } from "./codec.js";
import { makeEar } from "./ear.js";

export { SAMPLE_RATE };

const HERE = path.dirname(fileURLToPath(import.meta.url));

export const Ear = makeEar(createNativeSdk({
  here: HERE,
  packageName: PACKAGE_NAME,
  modelId: MODEL_ID,
  coreName: "EarNode",
}));
