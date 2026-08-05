// @desert-ant-labs/core: shared JavaScript runtime for Desert Ant Labs on-device
// model SDKs. This entry is browser-safe (no `node:*`): the shared model-SDK
// runtime (load / run / dispose over either core), the LiteRT.js host and
// session contract, the LiteRT loader/guards, the self-hosted-model fetch
// helper, the browser platform seam, and the FFI codecs. Optional audio support
// lives in the "./audio" subpath. Node-only code lives in "./node".
export { FfiReader, FfiWriter } from "./src/ffi.js";
export { makeCallGroups, CALL_GROUP_END_SYMBOL } from "./src/callgroup.js";
export { createWasmSdk, LoadedModel, readyModel, wasmCore } from "./src/sdk.js";
export {
  loadLiteRt,
  assertBrowserRuntime,
  installLiteRtHost,
  fetchSelfHostedModel,
  browserSetup,
  wasmExports,
  browserWasmDir,
  browserReadModelSource,
  browserCacheRoot,
} from "./src/litert.js";
