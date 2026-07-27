/** The result __PRODUCT__ produces. */
export interface __PRODUCT__Result {
  label: string;
  confidence: number;
}

export interface LoadOptions {
  /** Adopt an already-populated model directory instead of downloading. */
  directory?: string;
  /** Base for the managed cache (Node only). */
  cacheRoot?: string;
  /** Serve the model from your own origin instead of the Hub (browser). */
  modelBaseUrl?: string;
  /** 0...1 download progress. */
  onProgress?: (fraction: number) => void;
  /** Inject a LiteRT.js module (tests/custom builds). */
  litert?: unknown;
  /** Override where LiteRT.js loads its wasm runtime from. */
  litertWasmDir?: string;
  /** "wasm" (default) or "webgpu". */
  accelerator?: string;
}

export interface RunOptions {
  minimumConfidence?: number;
}

/** On-device __DESCRIPTION_SHORT__. */
export class __PRODUCT__ {
  static load(options?: LoadOptions): Promise<__PRODUCT__>;
  run(input: string, options?: RunOptions): Promise<__PRODUCT__Result | null>;
  dispose(): void;
}
