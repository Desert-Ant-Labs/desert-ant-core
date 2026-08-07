// Type declarations for the SSR-safe node seam of
// @desert-ant-labs/core/platform-node (no koffi in this graph).

/** Instantiate the wasm core under Node (WASI shim) and return its exports (the
 *  BridgeJS-generated wasm ABI). */
export function nodeSetup(options: {
  hostGlobal: string;
  instantiate: () => Promise<{ instantiate: Function }>;
  nodePlatform: () => Promise<{ defaultNodeSetup: Function }>;
}): Promise<import("./index.js").WasmCore>;

export function nodeWasmDir(): Promise<string>;
export function nodeReadModelSource(source: any): Promise<any>;
export function nodeCacheRoot(): Promise<string>;
