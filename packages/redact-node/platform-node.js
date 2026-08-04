// Node half of the platform seam for the universal WebAssembly entry
// (browser.js) when it runs server-side, e.g. the Client-Component SSR pass a
// framework renders in Node. The node-only work (WASI instantiate + node fs
// seam) lives in @desert-ant-labs/core/node; this file binds it to Redact's
// host/exports globals and dist entry points. Bundlers resolve this file only
// through the non-browser ("default") condition of `#platform`, so the browser
// bundle never sees `node:*`.
import { nodeSetup, nodeWasmDir, nodeReadModelSource, nodeCacheRoot } from "@desert-ant-labs/core/node";

export function setupCore() {
  return nodeSetup({
    hostGlobal: "__RedactHost",
    exportsGlobal: "__RedactExports",
    instantiate: () => import("./dist/instantiate.js"),
    nodePlatform: () => import("./dist/platforms/node.js"),
  });
}

export const defaultWasmDir = nodeWasmDir;
export const readModelSource = nodeReadModelSource;
export const defaultCacheRoot = nodeCacheRoot;
