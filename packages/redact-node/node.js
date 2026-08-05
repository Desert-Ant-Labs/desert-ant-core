// On-device multilingual PII redaction for JavaScript, server-side (Node). This
// is the `node` conditional-exports entry: the same Redact API as the browser
// build, but natively via the prebuilt Swift core (LiteRT/Core ML under the
// hood) instead of WebAssembly + LiteRT.js. Consumers just `import { Redact }` -
// Node resolves this file, browsers resolve `browser.js`. No flags, no setup.
//
// The koffi harness (resolve native/<platform>-<arch>, load the runtime, bind
// the generic `dal_*` C ABI, run blocking calls off the event loop) lives in
// @desert-ant-labs/core/node, and the public API is `redact.js`, shared with the
// browser entry; this file only binds the two together.
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
