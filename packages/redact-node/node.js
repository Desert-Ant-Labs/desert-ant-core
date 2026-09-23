// The `node` conditional-exports entry: the same Redact API as browser.js, run
// through the prebuilt Swift core instead of WebAssembly. The koffi harness
// lives in @desert-ant-labs/core/node; the public API is `redact.js`.
import { fileURLToPath } from "node:url";
import path from "node:path";
import { createNativeSdk } from "@desert-ant-labs/core/node";
import { MODEL_ID, PACKAGE_NAME } from "./codec.js";
import { makeRedact, DEFAULT_LABELS, ALL_LABELS } from "./redact.js";

export { DEFAULT_LABELS, ALL_LABELS };

const HERE = path.dirname(fileURLToPath(import.meta.url));

export const Redact = makeRedact(createNativeSdk({
  here: HERE,
  packageName: PACKAGE_NAME,
  modelId: MODEL_ID,
  coreName: "RedactNode",
}));
