// The `node` conditional-exports entry: the same Toxic API as browser.js, run
// through the prebuilt Swift core instead of WebAssembly. The koffi harness
// lives in @desert-ant-labs/core/node; the public API is `toxic.js`.
import { fileURLToPath } from "node:url";
import path from "node:path";
import { createNativeSdk } from "@desert-ant-labs/core/node";
import { MODEL_ID, PACKAGE_NAME } from "./codec.js";
import { makeToxic } from "./toxic.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));

export const Toxic = makeToxic(createNativeSdk({
  here: HERE,
  packageName: PACKAGE_NAME,
  modelId: MODEL_ID,
  coreName: "ToxicNode",
}));
