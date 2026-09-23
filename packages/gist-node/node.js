// The `node` conditional-exports entry: the same Gist API as browser.js, run
// through the prebuilt Swift core instead of WebAssembly. The koffi harness
// lives in @desert-ant-labs/core/node; the public API is `gist.js`.
import { fileURLToPath } from "node:url";
import path from "node:path";
import { createNativeSdk } from "@desert-ant-labs/core/node";
import { MODEL_ID, PACKAGE_NAME } from "./codec.js";
import { makeGist } from "./gist.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));

export const Gist = makeGist(createNativeSdk({
  here: HERE,
  packageName: PACKAGE_NAME,
  modelId: MODEL_ID,
  coreName: "GistNode",
}));

// The channel roll-up is pure JS over scores this package already returns - no
// model, no core - so both entries re-export the one implementation.
export { channelTopics } from "./channel.js";
