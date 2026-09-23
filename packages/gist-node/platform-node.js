// Node half of the `#platform` seam, for browser.js running server-side (e.g.
// an SSR pass). Resolved only through the non-browser condition, so the browser
// bundle never sees `node:*`.
//
// Imports the koffi-free "/platform-node" entry, never "/node": the native
// loader behind "/node" drags koffi's native addons into the SSR chunk, which
// bundlers cannot place in ESM output.
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
