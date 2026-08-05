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

export function installLiteRtHost(options: {
  hostGlobal: string;
  accelerator?: "wasm" | "webgpu" | string;
  loadAndCompile: (data: Uint8Array, opts: { accelerator: string }) => Promise<any>;
  Tensor: new (data: any, dims: number[]) => any;
  readModelSource: (source: any) => Promise<any>;
}): { setModel: (model: any) => void };

export function fetchModelFrom(
  baseUrl: string,
  files: { meta: string; model: string },
): Promise<{ metaJSON: string; modelBytes: Uint8Array }>;

/** The model-agnostic WebAssembly ABI a Desert Ant core installs, the twin of
 *  the native `dal_*` symbols. Handles are opaque numbers. */
export interface WasmCore {
  create(cacheRoot?: string, directory?: string): number;
  createSelfHosted(files: Record<string, string | Uint8Array>): number;
  isDownloaded(handle: number): boolean;
  download(handle: number, onProgress?: (fraction: number) => void): Promise<boolean>;
  run(
    handle: number,
    text: string,
    options?: Uint8Array | null,
    group?: string | null,
    deviceId?: string | (() => string) | null,
  ): Promise<Uint8Array>;
  endCallGroup(id: string): void;
  destroy(handle: number): void;
  flushTelemetry(): Promise<boolean>;
}

export function browserSetup(options: {
  hostGlobal: string;
  modelId: string;
  init: () => Promise<{ init: (arg: object) => Promise<unknown> }>;
}): Promise<WasmCore>;

/** The registered ABI for `modelId` (`globalThis.__DesertAntExports[modelId]`). */
export function wasmExports(modelId: string): WasmCore;

export function browserWasmDir(): Promise<string>;
export function browserReadModelSource(source: any): Promise<any>;
export function browserCacheRoot(): Promise<string>;
