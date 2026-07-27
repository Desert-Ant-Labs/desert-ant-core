// Browser half of the platform seam. Bundlers resolve this through the "browser"
// import condition of `#platform`, so none of the node-only code in
// platform-node.js enters the browser module graph.
import { browserSetup, browserWasmDir, browserReadModelSource, browserCacheRoot } from "@desert-ant-labs/core";

export function setupCore() {
  return browserSetup({
    hostGlobal: "__HOSTGLOBAL__",
    exportsGlobal: "__EXPORTSGLOBAL__",
    init: () => import("./dist/index.js"),
  });
}

export const defaultWasmDir = browserWasmDir;
export const readModelSource = browserReadModelSource;
export const defaultCacheRoot = browserCacheRoot;
