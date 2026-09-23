// Browser half of the `#platform` seam, resolved through the "browser" import
// condition so the node-only code in platform-node.js never enters the browser
// module graph.
import { browserSetup, browserWasmDir, browserReadModelSource, browserCacheRoot } from "@desert-ant-labs/core";

export function setupCore() {
  return browserSetup({ init: () => import("./dist/index.js") });
}

export const defaultWasmDir = browserWasmDir;
export const readModelSource = browserReadModelSource;
export const defaultCacheRoot = browserCacheRoot;
