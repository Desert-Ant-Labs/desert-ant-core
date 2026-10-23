// The `node` conditional-exports entry: the same Who API as browser.js, run
// through the prebuilt Swift core instead of WebAssembly. The koffi harness
// lives in @desert-ant-labs/core/node; the public API is `who.js`.
import { fileURLToPath } from "node:url";
import path from "node:path";
import { installAudioHost } from "@desert-ant-labs/core/audio/node";
import { createNativeSdk } from "@desert-ant-labs/core/node";
import { MODEL_ID, PACKAGE_NAME } from "./codec.js";
import { makeWho } from "./who.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));

export const Who = makeWho(createNativeSdk({
  here: HERE,
  packageName: PACKAGE_NAME,
  modelId: MODEL_ID,
  coreName: "WhoNode",
}), (bytes, sampleRate) => installAudioHost().decode(null, bytes, sampleRate));

export { Diarization, Turn } from "./diarization.js";
