// The model-specific half of this package's types. Everything that is the same
// for every model, such as how a model is loaded and its per-call options,
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions, ModelLoadOptions } from "@desert-ant-labs/core";
export { DesertAnt, type LogLevel } from "@desert-ant-labs/core";

/** The rate the model works at. Audio at any other rate is resampled. */
export declare const SAMPLE_RATE: 16000;

/** The confidence each bias preset gates at. */
export declare const BIAS: {
  readonly precision: 0.75;
  readonly balanced: 0.65;
  readonly recall: 0.5;
};

/** A key of {@link BIAS}. */
export type Bias = keyof typeof BIAS;

/** A filler span, in seconds from the start of the audio. */
export interface Filler {
  start: number;
  end: number;
  /** Model confidence for the span, `0...1`. */
  confidence: number;
  /** `"uh" | "um" | "hmm" | "and" | "other"` on Apple; null everywhere else,
   *  where the type labeler does not run. */
  type: string | null;
}

/** A transcript word, in seconds from the start of the audio. */
export interface Word {
  start: number;
  end: number;
  text: string;
}

export interface ReconcileOptions {
  /** Minimum overlap fraction (overlap / word duration) before a word is
   *  adjusted for a filler it only partly overlaps. Default 0.5. */
  minOverlapFraction?: number;
  /** When a word strictly contains a filler, emit both halves instead of the
   *  longer one. Default false. */
  splitContainedWords?: boolean;
}

export interface DetectOptions extends CallOptions {
  /** Threshold preset. Default `"balanced"`. */
  bias?: Bias;
  /** Explicit confidence threshold; overrides `bias`. */
  minConfidence?: number;
  /** Drop spans shorter than this, in seconds. Default 0.12. */
  minDurationSec?: number;
  /** Run the per-filler type labeler where one exists (Apple). Default true. */
  includeTypes?: boolean;
  /** Transcript words to reconcile against the detected fillers. */
  words?: Word[];
  reconcile?: ReconcileOptions;
}

export interface DetectResult {
  /** Detected fillers, in time order. */
  fillers: Filler[];
  /** Total decoded audio length, in seconds. */
  audioDuration: number;
  /** The `words` you passed, trimmed, split, or dropped so a cut at a filler
   *  never clips a real word. Null when no words were passed. */
  words: Word[] | null;
}

/** On-device filler-word detection. */
export declare class Uhm {
  /** Load the model, downloading and caching it on first use. */
  static load(options?: ModelLoadOptions): Promise<Uhm>;
  /** Find filler spans in mono `samples` at `sampleRate`. */
  detect(samples: Float32Array | number[], sampleRate?: number,
         options?: DetectOptions): Promise<DetectResult>;
  /** Whether the model is usable with no network. */
  isDownloaded(): boolean;
  /** @deprecated Has no effect: runs `body` with a group id that nothing reads. */
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  /** Wait for the license requests in flight. */
  flushTelemetry(): Promise<boolean>;
  /** Release the model. */
  dispose(): void;
}
