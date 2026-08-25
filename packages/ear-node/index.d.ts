// The model-specific half of this package's types. Everything that is the same
// for every model - how a model is loaded, how a call is billed and attributed -
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions, ModelLoadOptions } from "@desert-ant-labs/core";

/** The rate the model works at. Audio at any other rate is resampled. */
export declare const SAMPLE_RATE: 16000;

/** A candidate language and how likely the model thinks it is. */
export interface LanguageCandidate {
  /** ISO 639-1 where one exists, otherwise 639-3. */
  language: string;
  /** `0...1`, averaged over the windows that were listened to. */
  probability: number;
}

/** What the model heard. */
export interface Detection {
  /** The detected language, or null if there was nothing to listen to. */
  language: string | null;
  /** The detected language's probability, `0...1`. */
  confidence: number;
  /** Candidates, most likely first. */
  candidates: LanguageCandidate[];
  /** How many windows of audio the answer is averaged over. */
  windows: number;
  /**
   * Whether this answer is worth routing work on.
   *
   * False when the top two candidates are too close to separate, and false for
   * the Nordic languages, which the model confuses with each other confidently
   * rather than uncertainly - so their probability does not reveal the problem
   * and a margin test cannot catch it. Branch on this rather than on
   * `confidence`.
   */
  isReliable: boolean;
}

export interface IdentifyOptions extends CallOptions {
  /**
   * How many thirty-second windows to listen to. Three by default, chosen by
   * how speech-like they are rather than by position, so a jingle or a long
   * silence does not decide the answer. Shorter recordings use fewer.
   */
  windows?: number;
}

/**
 * On-device spoken language identification.
 *
 * ```ts
 * const ear = await Ear.load();
 * const d = await ear.identify(samples, 16000);
 * if (d.isReliable) route(d.language);
 * ```
 */
export declare class Ear {
  /** Load the model, downloading and caching it on first use. */
  static load(options?: ModelLoadOptions): Promise<Ear>;
  /** Name the language of mono `samples` at `sampleRate`. */
  identify(samples: Float32Array | number[], sampleRate?: number,
           options?: IdentifyOptions): Promise<Detection>;
  /** Whether the model is usable with no network. */
  isDownloaded(): boolean;
  /** Bill several calls as one. */
  withCallGroup<T>(body: (group: number) => Promise<T> | T): Promise<T>;
  /** Release the model. */
  dispose(): void;
}
