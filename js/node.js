// @desert-ant-labs/core/node: the node-only pieces for a model package's native
// server-side entry. The native koffi loader (loadNative, callAsync,
// decodeResult) plus the node half of the platform seam. Importing this pulls in
// `node:*`, so browser bundles must import from "@desert-ant-labs/core" instead.
export { loadNative } from "./src/native.js";
export {
  nodeSetup,
  nodeWasmDir,
  nodeReadModelSource,
  nodeCacheRoot,
} from "./src/platform-node.js";
export { FfiReader } from "./src/ffi.js";
