// @desert-ant-labs/core: shared JavaScript runtime for Desert Ant Labs on-device
// model SDKs. This entry is browser-safe (no `node:*`): the LiteRT.js host and
// session contract, the LiteRT loader/guards, the self-hosted-model fetch
// helper, the browser platform seam, and the FFI reader. The node-only native
// loader and node platform seam live in the "./node" subpath.
export { FfiReader } from "./src/ffi.js";
export { installAudioHost } from "./src/audio.js";
export { decodeWav, mixdownMono, resampleLinear } from "./src/wav.js";
export {
  loadLiteRt,
  assertBrowserRuntime,
  installLiteRtHost,
  fetchModelFrom,
  browserSetup,
  browserWasmDir,
  browserReadModelSource,
  browserCacheRoot,
} from "./src/litert.js";
