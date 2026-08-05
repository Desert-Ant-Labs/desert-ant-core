// @desert-ant-labs/core/node: the node-only pieces for a model package's native
// server-side entry. The native SDK factory (createNativeSdk) and the koffi
// loader under it (loadNative, callAsync, decodeResult), plus the node half of
// the platform seam. Importing this pulls in `node:*`, so browser bundles must
// import from "@desert-ant-labs/core" instead.
export { createNativeSdk } from "./src/native-sdk.js";
export { loadNative, DAL_SYMBOLS, DEFAULT_CORE_NAME } from "./src/native.js";
export { makeCallGroups, CALL_GROUP_END_SYMBOL } from "./src/callgroup.js";
export {
  nodeSetup,
  nodeWasmDir,
  nodeReadModelSource,
  nodeCacheRoot,
} from "./src/platform-node.js";
export { FfiReader, FfiWriter } from "./src/ffi.js";
