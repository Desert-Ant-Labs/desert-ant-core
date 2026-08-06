// @desert-ant-labs/core/node: the node-only pieces for a model package's native
// server-side entry. The native SDK factory (createNativeSdk) and the koffi
// loader under it (loadNative, callAsync, decodeResult).
//
// Importing this pulls in `node:*` *and* koffi, whose native `.node` addons
// cannot be placed in a bundler's ESM chunk, so only a package's `/native` entry
// may import it. Browser bundles import "@desert-ant-labs/core"; the Node half
// of the `#platform` seam (the SSR path of the universal wasm entry) imports
// "@desert-ant-labs/core/platform-node", which stays koffi-free.
export { createNativeSdk } from "./src/native-sdk.js";
export { loadNative, dalSymbols } from "./src/native.js";
export { makeCallGroups, CALL_GROUP_END_SYMBOL } from "./src/callgroup.js";
export { FfiReader, FfiWriter } from "./src/ffi.js";
