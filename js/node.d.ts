// Type declarations for the node-only entry of @desert-ant-labs/core/node.
// The `#platform` seam (nodeSetup and friends) lives in ./platform-node.d.ts so
// the SSR graph never reaches koffi.
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

/** This model's C ABI, keyed by friendly name: generic `dal_*` calls plus the
 *  per-model `<modelId>_create` constructor. */
export function dalSymbols(modelId: string): Record<string, string>;

export function loadNative(options: {
  here: string;
  packageName: string;
  coreName: string;
  modelId: string;
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
  coreName: string;
}): import("./index.js").ModelSdk;

export interface CallGroups {
  withCallGroup: <T>(body: (group: string) => Promise<T>) => Promise<T>;
}

/** The generic C prototype every SDK core exports to release a call group. */
export const CALL_GROUP_END_SYMBOL: string;

/** Build the call-group API around a native group-release function. */
export function makeCallGroups(endGroup: (id: string) => void): CallGroups;
