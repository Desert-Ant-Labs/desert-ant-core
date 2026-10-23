// Browser half of the `#platform` seam, resolved through the "browser" import
// condition so the node-only code in platform-node.js never enters the browser
// module graph.
import { browserSetup, browserWasmDir, browserReadModelSource, browserCacheRoot } from "@desert-ant-labs/core";
import { installAudioHost } from "@desert-ant-labs/core/audio";

export function setupCore() {
  return browserSetup({ init: () => import("./dist/index.js") });
}

export const defaultWasmDir = browserWasmDir;
export const readModelSource = browserReadModelSource;
export const defaultCacheRoot = browserCacheRoot;

/** Web Audio decodes any container the browser supports and renders it to mono at `sampleRate`. */
export function decodeAudio(bytes, sampleRate) {
  return installAudioHost().decode(null, bytes, sampleRate);
}
