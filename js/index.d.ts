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
 *  Swift's `FFIReader`): a model's `dal_run` options, or a file manifest for
 *  `dal_create_from_files`. */
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

export function browserSetup(options: {
  hostGlobal: string;
  exportsGlobal: string;
  init: () => Promise<{ init: (arg: object) => Promise<unknown> }>;
}): Promise<any>;

export function browserWasmDir(): Promise<string>;
export function browserReadModelSource(source: any): Promise<any>;
export function browserCacheRoot(): Promise<string>;
