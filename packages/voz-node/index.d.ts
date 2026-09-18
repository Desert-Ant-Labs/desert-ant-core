/** A word and when it sounds, in seconds from the start of the audio. Times
 *  land on encoder frame boundaries, so their resolution is 80 ms. */
export interface VozWord {
  text: string;
  start: number;
  end: number;
}

export interface VozResult {
  /** The transcript. */
  text: string;
  /** Every word, in order, with its start and end. */
  words: VozWord[];
  /** Seconds of audio. */
  duration: number;
  /** Seconds of wall clock spent transcribing it. */
  processingTime: number;
  /** Seconds of audio per second of wall clock. */
  realtimeFactor: number;
}

export interface VozTimings {
  calls: Record<string, number>;
  millis: Record<string, number>;
}

export interface VozLoadOptions {
  /** An ONNX Runtime module to use instead of the default.
   *
   *  In a browser there is a default: install `onnxruntime-web` alongside this
   *  package and it is imported on demand. Under Node there is not, because the
   *  runtime there is a native addon that cannot be bundled, so pass
   *  `onnxruntime-node`. */
  ort?: any;
  /** Serve the bundle yourself instead of from the Hub. Must end in "/". */
  modelBaseUrl?: string;
  /** A different Hub revision of the bundle. */
  revision?: string;
  /** Override the WebNN detection. WebNN runs the decode step on the Neural
   *  Engine where the browser has it. */
  webnn?: boolean;
  /** Where onnxruntime-web's own .wasm files are served from. */
  wasmDir?: string;
  /** Fraction in [0, 1] as the bundle downloads. */
  onProgress?: (fraction: number) => void;
  /** Cache the downloaded bundle (Cache API in the browser, disk in Node).
   *  Default true. */
  cache?: boolean;
  /** Where the graphs run. "auto" (the default) takes WebGPU when the adapter
   *  can compile this encoder's f16 shaders and the CPU when it cannot, which
   *  is what a machine with no GPU looks like. */
  ep?: "auto" | "webgpu" | "wasm";
}

export interface VozTranscribeOptions {
  /** Fraction in [0, 1] as the audio is transcribed. */
  onProgress?: (fraction: number) => void;
  /** The rate of `Float32Array` samples, when it is not 16 kHz. */
  sampleRate?: number;
}

/**
 * What `transcribe` accepts.
 *
 * A `File`, a `Blob`, or (under Node) a path is read in pieces, so memory does
 * not grow with the length of the recording. Samples are taken as they are.
 */
export type VozAudio =
  | Blob
  | string
  | Float32Array
  | { samples: Float32Array | ArrayLike<number>; sampleRate?: number }
  | ArrayBuffer
  | Uint8Array;

export declare class Voz {
  /** Fetch the bundle, compile it, and load the core. Hold the instance and
   *  reuse it: it carries three compiled graphs and 1.19 GB of weights. */
  static load(options?: VozLoadOptions): Promise<Voz>;
  /** Transcribe audio, with a start and an end on every word. */
  transcribe(input: VozAudio, options?: VozTranscribeOptions): Promise<VozResult>;
  /** Per-model call counts and wall time for the last transcription. */
  readonly timings: VozTimings;
}

/** The rate the model's frontend takes. Anything else is resampled. */
export declare const SAMPLE_RATE: number;

/** What this model is, as the core reports it from `Sources/Voz/Catalog.swift`.
 *  `files` is what a `modelBaseUrl` has to serve. */
export interface VozModelInfo {
  id: string;
  sdkVersion: string;
  repo: string;
  revision: string;
  files: string[];
}

/** A transcript as the core returns it, before the package adds
 *  `realtimeFactor`. */
export interface VozTranscript {
  text: string;
  words: VozWord[];
  duration: number;
  processingTime: number;
}

/**
 * Voz's WebAssembly core: its own surface, not the shared model-agnostic one
 * (`WasmCore` in @desert-ant-labs/core), because this model runs three graphs
 * and returns a transcript rather than one `run` over FFI payloads.
 *
 * Declared here so `mise run check:types` can assert it is identical to what
 * BridgeJS generates from `Sources/Voz/Web/Bridge.swift`: a Swift signature
 * that changed without this changing fails that check. Internal to the package
 * - callers use `Voz` above - but exported because the check has to name it.
 */
export interface ModelCore {
  modelInfo(): VozModelInfo;
  transcribeStream(
    seconds: number, totalSamples: number,
    pull: (arg0: number) => any | null,
    onProgress: (arg0: number) => void,
  ): Promise<VozTranscript>;
  load(
    meta: Uint8Array, vocab: Uint8Array, embedding: Uint8Array,
    lanes: number, batch: number, fused: boolean,
  ): Promise<boolean>;
  isLoaded(): boolean;
  transcribe(
    samples: Float32Array, onProgress: (arg0: number) => void,
  ): Promise<VozTranscript>;
}
