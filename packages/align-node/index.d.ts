// The model-specific half of this package's types. How a model is loaded, billed and attributed
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions } from "@desert-ant-labs/core";

/** One word of a transcript. Any other keys you carry are returned untouched. */
export interface Word { text: string; start: number; end: number; [key: string]: unknown; }

/** How the model is located. The native core has no browser-side options. */
export interface AlignLoadOptions {
  /** A directory that holds (or will hold) the model files; populated means offline, as-is. */
  directory?: string;
  /** Override the managed cache root the default download lands under. */
  cacheRoot?: string;
  /** Download progress, 0 to 1. */
  onProgress?: (fraction: number) => void;
}

export interface RefineOptions extends CallOptions {
  /** BCP-47 or bare ISO code of the transcript's language, for example "en" or "pt-BR". */
  language: string;
}

export declare class Align {
  private constructor();
  /** The nine language codes the model was trained on. */
  static readonly languages: readonly string[];
  /** True when `refine` will correct times for this language; false means passthrough. */
  static isSupported(language: string): boolean;
  /** This package's version, the same number as the core it pins. Set on the `/native` entry. */
  static readonly sdkVersion: string;
  static load(options?: AlignLoadOptions): Promise<Align>;
  /** Instance mirrors of the three statics, so a caller holding a loaded model needs no class reference. */
  readonly languages: readonly string[];
  isSupported(language: string): boolean;
  readonly sdkVersion: string;
  /**
   * Every word's `start` and `end` must be a finite number from -1 to 10,000,000 seconds, `sampleRate` finite and
   * positive, and `samples` non-empty; otherwise this rejects with a `RangeError`. A word more than about 1.2 s past
   * the end of the audio keeps its times, `refined: false`.
   */
  refine<W extends Word>(samples: Float32Array | number[], sampleRate: number, words: W[],
                         options: RefineOptions): Promise<(W & { refined: boolean })[]>;
  isDownloaded(): boolean;
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  /** Send recorded usage and await the POST. One load per device per call. */
  flushTelemetry(): Promise<boolean>;
  dispose(): void;
}
