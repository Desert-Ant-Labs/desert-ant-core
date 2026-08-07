// Node half of the platform seam for the universal WebAssembly entry
// (browser.js) when it runs server-side, e.g. the Client-Component SSR pass a
// framework renders in Node. The node-only work (WASI instantiate + node fs
// seam) lives in @desert-ant-labs/core/platform-node; this file binds it to
// Emo's host/exports globals and dist entry points. Bundlers resolve this file
// only through the non-browser ("default") condition of `#platform`, so the
// browser bundle never sees `node:*`.
//
// This imports the koffi-free "/platform-node" entry, never "/node": the native
// loader behind "/node" drags koffi's native addons into the SSR chunk, which
// bundlers cannot place in ESM output.
import { nodeSetup, nodeWasmDir, nodeReadModelSource, nodeCacheRoot } from "@desert-ant-labs/core/platform-node";
import { HOST_GLOBAL } from "./codec.js";

export function setupCore() {
  return nodeSetup({
    hostGlobal: HOST_GLOBAL,
    instantiate: () => import("./dist/instantiate.js"),
    nodePlatform: () => import("./dist/platforms/node.js"),
  });
}

export const defaultWasmDir = nodeWasmDir;
export const readModelSource = nodeReadModelSource;
export const defaultCacheRoot = nodeCacheRoot;
