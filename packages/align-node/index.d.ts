// The model-specific half of this package's types. How a model is loaded, billed and attributed
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions, ModelLoadOptions } from "@desert-ant-labs/core";

/** One word of a transcript. Any other keys you carry are returned untouched. */
export interface Word { text: string; start: number; end: number; [key: string]: unknown; }

export interface RefineOptions extends CallOptions {
  /** BCP-47 or bare ISO code of the transcript's language, for example "en" or "pt-BR". */
  language: string;
}

export declare class Align {
  /** The nine language codes the model was trained on. */
  static readonly languages: readonly string[];
  /** True when `refine` will correct times for this language; false means passthrough. */
  static isSupported(language: string): boolean;
  /** This package's version, the same number as the core it pins. Set on the `/native` entry. */
  static readonly sdkVersion: string;
  static load(options?: ModelLoadOptions): Promise<Align>;
  /** Instance mirrors of the three statics, so a caller holding a loaded model needs no class reference. */
  readonly languages: readonly string[];
  isSupported(language: string): boolean;
  readonly sdkVersion: string;
  refine<W extends Word>(samples: Float32Array | number[], sampleRate: number, words: W[],
                         options: RefineOptions): Promise<(W & { refined: boolean })[]>;
  isDownloaded(): boolean;
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  dispose(): void;
}
