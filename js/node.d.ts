// Type declarations for the node-only entry of @desert-ant-labs/core/node.
import { FfiReader } from "./index.js";
export { FfiReader };

export interface NativeCore {
  koffi: any;
  /** Lazily loads + binds the native library on first property access. */
  lib: Record<string, any>;
  callAsync: (fn: any, ...args: any[]) => Promise<any>;
  /** Decode a result pointer into a reader positioned at the payload start. */
  decodeResult: (ptr: any) => FfiReader;
  version: string;
  nativeDir: () => string;
  defaultCacheRoot: () => string;
}

export function loadNative(options: {
  here: string;
  packageName: string;
  coreName: string;
  symbols: Record<string, string>;
  targets?: string[];
}): NativeCore;

export function nodeSetup(options: {
  hostGlobal: string;
  exportsGlobal: string;
  instantiate: () => Promise<{ instantiate: Function }>;
  nodePlatform: () => Promise<{ defaultNodeSetup: Function }>;
}): Promise<any>;

export function nodeWasmDir(): Promise<string>;
export function nodeReadModelSource(source: any): Promise<any>;
export function nodeCacheRoot(): Promise<string>;
