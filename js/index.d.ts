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

/** The audio-decode host the wasm AudioIO backend calls (`__DalAudioHost`). */
export interface AudioHost {
  decode(path: string | null, bytes: Uint8Array | null, sampleRate: number): Promise<Float32Array>;
}

/** Install `globalThis.__DalAudioHost` so the wasm core can decode audio.
 *  Browser: Web Audio (any container). Node (`/node` entry): the WAV codec. */
export function installAudioHost(): AudioHost;

/** Decode a WAV/RIFF buffer to interleaved float samples + rate + channels. */
export function decodeWav(bytes: Uint8Array): { samples: Float32Array; sampleRate: number; channels: number };
export function mixdownMono(interleaved: Float32Array, channels: number): Float32Array;
export function resampleLinear(x: Float32Array, from: number, to: number): Float32Array;

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
