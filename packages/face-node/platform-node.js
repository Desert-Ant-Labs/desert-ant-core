import { nodeSetup, nodeWasmDir, nodeReadModelSource, nodeCacheRoot } from "@desert-ant-labs/core/platform-node";

export function setupCore() {
  return nodeSetup({
    instantiate: () => import("./dist/instantiate.js"),
    nodePlatform: () => import("./dist/platforms/node.js"),
  });
}

export const defaultWasmDir = nodeWasmDir;
export const readModelSource = nodeReadModelSource;
export const defaultCacheRoot = nodeCacheRoot;
