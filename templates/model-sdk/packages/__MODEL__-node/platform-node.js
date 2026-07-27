// Node half of the platform seam for the universal WebAssembly entry
// (browser.js). The node-only work lives in @desert-ant-labs/core/node; this
// file binds it to __PRODUCT__'s globals and dist entry points.
import { nodeSetup, nodeWasmDir, nodeReadModelSource, nodeCacheRoot } from "@desert-ant-labs/core/node";

export function setupCore() {
  return nodeSetup({
    hostGlobal: "__HOSTGLOBAL__",
    exportsGlobal: "__EXPORTSGLOBAL__",
    instantiate: () => import("./dist/instantiate.js"),
    nodePlatform: () => import("./dist/platforms/node.js"),
  });
}

export const defaultWasmDir = nodeWasmDir;
export const readModelSource = nodeReadModelSource;
export const defaultCacheRoot = nodeCacheRoot;
