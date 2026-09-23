// The `node` conditional-exports entry: the same Emo API as browser.js, run
// through the prebuilt Swift core instead of WebAssembly. The koffi harness
// lives in @desert-ant-labs/core/node; the public API is `emo.js`.
import { fileURLToPath } from "node:url";
import path from "node:path";
import { createNativeSdk } from "@desert-ant-labs/core/node";
import { MODEL_ID, PACKAGE_NAME } from "./codec.js";
import { makeEmo } from "./emo.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));

export const Emo = makeEmo(createNativeSdk({
  here: HERE,
  packageName: PACKAGE_NAME,
  modelId: MODEL_ID,
  coreName: "EmoNode",
}));
