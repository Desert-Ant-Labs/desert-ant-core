// Type declarations for the node-only entry of @desert-ant-labs/core/node.
import { FfiReader, AudioHost } from "./index.js";
export { FfiReader };

/** Install `globalThis.__DalAudioHost` backed by the pure-JS WAV codec (Node
 *  has no Web Audio). Reads the file at `path` through `node:fs`. */
export function installAudioHost(): AudioHost;

export interface NativeCore {
  koffi: any;
  /** Lazily loads + binds the native library on first property access. */
  lib: Record<string, any>;
  callAsync: (fn: any, ...args: any[]) => Promise<any>;
  /** Decode a result pointer into a reader positioned at the payload start. */
  decodeResult: (ptr: any) => FfiReader;
  /**
   * Run `body(group)` with a fresh usage call-group id. Every native call inside
   * that forwards `{ group }` bills as a single usage call; the group is released
   * when `body` settles.
   */
  withCallGroup: <T>(body: (group: string) => Promise<T>) => Promise<T>;
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

export interface CallGroups {
  withCallGroup: <T>(body: (group: string) => Promise<T>) => Promise<T>;
}

/** The generic C prototype every SDK core exports to release a call group. */
export const CALL_GROUP_END_SYMBOL: string;

/** Build the call-group API around a native group-release function. */
export function makeCallGroups(endGroup: (id: string) => void): CallGroups;

export function nodeWasmDir(): Promise<string>;
export function nodeReadModelSource(source: any): Promise<any>;
export function nodeCacheRoot(): Promise<string>;
