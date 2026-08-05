// Type declarations for the node-only entry of @desert-ant-labs/core/node.
import { FfiReader, FfiWriter } from "./index.js";
export { FfiReader, FfiWriter };

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

/** The one native core every model package loads: "DesertAntNode". */
export const DEFAULT_CORE_NAME: string;

/** The generic `dal_*` C ABI (Sources/Bindings/CABI.swift), keyed by friendly
 *  name. The model is a `modelId` argument, so this is the same for every SDK. */
export const DAL_SYMBOLS: Record<string, string>;

export function loadNative(options: {
  here: string;
  packageName: string;
  coreName?: string;
  symbols?: Record<string, string>;
  targets?: string[];
}): NativeCore;

/** The native (server-side Node) half of a model package: bind the prebuilt
 *  Swift core with koffi and return a bound SDK with the same shape as
 *  `createWasmSdk`, so a package's public class is written once. */
export function createNativeSdk(options: {
  here: string;
  packageName: string;
  modelId: string;
  coreName?: string;
}): import("./index.js").ModelSdk;

export function nodeSetup(options: {
  hostGlobal: string;
  modelId: string;
  instantiate: () => Promise<{ instantiate: Function }>;
  nodePlatform: () => Promise<{ defaultNodeSetup: Function }>;
}): Promise<import("./index.js").WasmCore>;

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
