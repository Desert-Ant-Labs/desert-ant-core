// On-device structured extraction for JavaScript, server-side (Node). This is the
// `node` conditional-exports entry: the same Schemer API as the browser build,
// but natively via the prebuilt Swift core (LiteRT/Core ML under the hood)
// instead of WebAssembly + LiteRT.js. Consumers just `import { Schemer }` - Node
// resolves this file, browsers resolve `browser.js`. No flags, no setup.
//
// The koffi harness (resolve native/<platform>-<arch>, load the runtime, bind
// the generic `dal_*` C ABI, run blocking calls off the event loop) lives in
// @desert-ant-labs/core/node, and the public API is `schemer.js`, shared with the
// browser entry; this file only binds the two together.
import { fileURLToPath } from "node:url";
import path from "node:path";
import { createNativeSdk } from "@desert-ant-labs/core/node";
import { MODEL_ID, PACKAGE_NAME } from "./codec.js";
import { makeSchemer } from "./schemer.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));

export const Schemer = makeSchemer(createNativeSdk({
  here: HERE,
  packageName: PACKAGE_NAME,
  modelId: MODEL_ID,
  coreName: "SchemerNode",
}));

/** The compiled label graph takes at most this many candidate values. */
export { MAX_LABEL_VALUES, TRUNCATED } from "./codec.js";
