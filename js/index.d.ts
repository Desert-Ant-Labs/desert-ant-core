// Type declarations for the browser-safe entry of @desert-ant-labs/core.

/** A named tensor exchanged with the wasm core / LiteRT.js host. */
export interface HostTensor {
  data: Uint8Array;
  dims: number[];
  type: "int32" | "float32" | "uint8" | string;
}

/** Big-endian cursor over the length-prefixed FFIBuffer payload the native core
 *  returns (the JS counterpart of Kotlin's FfiReader and Swift's FFIWriter). */
export class FfiReader {
  constructor(bytes: Uint8Array);
  u32(): number;
  i32(): number;
  f64(): number;
  bytes(n: number): Uint8Array;
  str(): string;
  readonly offset: number;
  readonly remaining: number;
}

/** Builds the FFIBuffer payloads the native core reads (the JS counterpart of
 *  Swift's `FFIReader`): a model's `dal_run` options. */
export class FfiWriter {
  u32(v: number): this;
  f64(v: number): this;
  str(s: string): this;
  strings(values: Iterable<string>): this;
  blob(bytes: Uint8Array | ArrayLike<number>): this;
  raw(bytes: Uint8Array | ArrayLike<number>): this;
  readonly length: number;
  done(): Uint8Array;
}

export function loadLiteRt(options: {
  litert?: any;
  wasmDir?: string;
  defaultWasmDir: () => Promise<string>;
  packageName: string;
}): Promise<any>;

export function assertBrowserRuntime(options: { packageName: string; litert?: any }): void;

/** A tensor crossing to or from the JS host, mirroring `HostTensor` in
 *  Sources/JSHost/Host.swift. */
export interface HostTensor {
  data: Uint8Array;
  dims: number[];
  type: string;
}

/** The model host a wasm core is instantiated with: the JS half of the contract
 *  BridgeJS generates from Sources/JSHost/Host.swift, whose generated form is a
 *  package's own `dist/bridge-js.d.ts` (`Imports`). `mise run check:types` proves
 *  this matches it. */
export interface ModelHost {
  createSessionFromPath(path: string): Promise<void>;
  createSessionFromBytes(bytes: Uint8Array): Promise<void>;
  run(inputs: Record<string, HostTensor>): Promise<Record<string, HostTensor>>;
}

/** The import object a core is instantiated with. */
export interface HostImports {
  readonly dalModelHost: ModelHost;
}

/** A stable import object whose methods forward to whatever host is installed:
 *  a core instantiates at import time, its LiteRT session exists only after
 *  `load()`. */
export function makeModelHostSeam(): {
  imports: HostImports;
  install: (host: ModelHost) => void;
};

/** The LiteRT.js implementation of that contract, plus the `setModel` hook the
 *  `modelBaseUrl` path uses to supply a model the page compiled itself. */
export function makeLiteRtHost(options: {
  accelerator?: "wasm" | "webgpu" | string;
  loadAndCompile: (data: Uint8Array, opts: { accelerator: string }) => Promise<any>;
  Tensor: new (data: any, dims: number[]) => any;
  readModelSource: (source: any) => Promise<any>;
}): { host: ModelHost; setModel: (model: any) => void };

/** What a core reports about its model, from the Swift catalog declaration.
 *  Mirrors `ModelInfo` in Sources/WasmBindings/Exports.swift. */
export interface ModelInfo {
  id: string;
  sdkVersion: string;
  /** The runnable artifact, compiled by the host (never crosses into the core). */
  artifact: string;
  /** Sidecars handed to the core, keyed by these names. */
  sidecars: string[];
}

/** Names a `modelBaseUrl` must serve, as in the model catalog. */
export interface ModelFileNames {
  /** The runnable artifact, compiled by the host (never crosses into the core). */
  model: string;
  /** Sidecars handed to the core, keyed by these names. */
  sidecars: string[];
}

export function fetchSelfHostedModel(
  baseUrl: string,
  files: ModelFileNames,
): Promise<{ sidecars: Record<string, Uint8Array>; modelBytes: Uint8Array }>;

/** How a call is billed and attributed. */
export interface CallOptions {
  /** Bills this call as part of a group from {@link LoadedModel.withCallGroup}. */
  group?: string;
  /** Attributes usage to an end-user device; resolved per call. */
  deviceId?: string | (() => string);
}

/** A loaded model behind an opaque core handle: what a model package's public
 *  class delegates to, identical on both runtimes. */
export class LoadedModel {
  run(text: string, options: Uint8Array, call?: CallOptions): Promise<FfiReader>;
  isDownloaded(): boolean;
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  dispose(): void;
}

/** How a model is loaded, shared by both runtimes. A model package extends this
 *  with its own inference options. */
export interface ModelLoadOptions {
  directory?: string;
  modelBaseUrl?: string;
  cacheRoot?: string;
  onProgress?: (fraction: number) => void;
  litert?: unknown;
  litertWasmDir?: string;
  accelerator?: "wasm" | "webgpu" | "webnn";
}

/** A bound SDK: `open(options)` resolves the model and returns it ready. */
export interface ModelSdk {
  core: NormalizedCore;
  open(options?: ModelLoadOptions): Promise<LoadedModel>;
}

/** Either core, normalized to what {@link LoadedModel} drives. */
export interface NormalizedCore {
  create(cacheRoot: string, directory: string | null): number;
  createSelfHosted?(files: Record<string, Uint8Array>): number;
  isDownloaded(handle: number): boolean;
  download(handle: number, onProgress?: (fraction: number) => void): Promise<void | boolean>;
  run(
    handle: number,
    text: string,
    options: Uint8Array | null,
    group: string | null,
    deviceId: string | null,
  ): Promise<FfiReader>;
  /** Audio models: samples in, the model's own payload out. */
  runAudio?(
    handle: number,
    samples: Float32Array,
    sampleRate: number,
    options: Uint8Array | null,
    group: string | null,
    deviceId: string | null,
  ): Promise<FfiReader>;
  destroy(handle: number): void;
  /** wasm only: force the usage POST out and await it (debug). */
  flushTelemetry?(): Promise<boolean>;
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
}

/** Wrap the WebAssembly ABI in the normalized core shape. */
export function wasmCore(exports: WasmCore): NormalizedCore;

/** Download/load a fresh handle and wrap it, so `load()` surfaces failures. */
export function readyModel(options: {
  core: NormalizedCore;
  packageName: string;
  handle: number;
  onProgress?: (fraction: number) => void;
}): Promise<LoadedModel>;

/** The browser/WebAssembly half of a model package: instantiate the core through
 *  the package's `#platform` seam and return a bound SDK. */
export function createWasmSdk(options: {
  platform: any;
  packageName: string;
}): Promise<ModelSdk>;

/** Mint a call-group id, run the body, release the group. */
export function makeCallGroups(endGroup: (id: string) => void): {
  withCallGroup: <T>(body: (group: string) => Promise<T>) => Promise<T>;
};

/** The generic C prototype every SDK core exports to release a call group. */
export const CALL_GROUP_END_SYMBOL: string;

/** The model-agnostic WebAssembly ABI a Desert Ant core exports, the twin of the
 *  native `dal_*` symbols. BridgeJS generates it from the `@JS` declarations in
 *  Sources/WasmBindings, so a model package's own `dist/bridge-js.d.ts` is the
 *  source of truth; core is model-agnostic and cannot import that, so this
 *  restates it and `mise run check:types` proves the two still agree. Handles are
 *  opaque numbers.
 */
export interface WasmCore {
  modelInfo(): ModelInfo;
  create(cacheRoot: string | null, directory: string | null): number;
  createSelfHosted(files: Record<string, Uint8Array>): number;
  isDownloaded(handle: number): boolean;
  download(handle: number, onProgress: (fraction: number) => void): Promise<boolean>;
  run(
    handle: number,
    text: string,
    options: Uint8Array | null,
    group: string | null,
    deviceId: string | null,
  ): Promise<Uint8Array>;
  runAudio(
    handle: number,
    samples: Float32Array,
    sampleRate: number,
    options: Uint8Array | null,
    group: string | null,
    deviceId: string | null,
  ): Promise<Uint8Array>;
  endCallGroup(id: string | null): void;
  destroy(handle: number): void;
  flushTelemetry(): Promise<boolean>;
}

/** An instantiated core: its exports, and the hook that installs the model host
 *  it was instantiated with. */
export interface InstantiatedCore {
  exports: WasmCore;
  installHost: (host: ModelHost) => void;
}

export function browserSetup(options: {
  init: () => Promise<{ init: (arg: object) => Promise<{ exports: WasmCore }> }>;
}): Promise<InstantiatedCore>;

export function browserWasmDir(): Promise<string>;
export function browserReadModelSource(source: any): Promise<any>;
export function browserCacheRoot(): Promise<string>;
