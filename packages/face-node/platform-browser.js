import { browserSetup, browserWasmDir, browserReadModelSource, browserCacheRoot } from "@desert-ant-labs/core";

export function setupCore() {
  return browserSetup({ init: () => import("./dist/index.js") });
}

export const defaultWasmDir = browserWasmDir;
export const readModelSource = browserReadModelSource;
export const defaultCacheRoot = browserCacheRoot;
