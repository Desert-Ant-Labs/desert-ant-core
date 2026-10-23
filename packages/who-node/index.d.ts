// The model-specific half of this package's types. Everything that is the same
// for every model - how a model is loaded, how a call is billed and attributed -
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions, ModelLoadOptions } from "@desert-ant-labs/core";

/** Decoded mono samples at a rate. */
export interface Samples {
  samples: Float32Array | ArrayLike<number>;
  /** Hz. Audio at any rate is accepted and resampled by the core. */
  sampleRate?: number;
}

/**
 * Anything `diarize` takes: the bytes of an audio file (decoded with Web Audio
 * in the browser, the portable WAV decoder in Node), mono `Float32Array`
 * samples at 16 kHz, or {@link Samples} at any rate.
 */
export type AudioInput = Blob | ArrayBuffer | Uint8Array | Float32Array | Samples;

/** Options for a single `diarize` call. */
export interface DiarizeOptions extends CallOptions {
  /** The rate of bare `Float32Array` samples, Hz. Default 16000. */
  sampleRate?: number;
}

/** One stretch of one speaker's speech. */
export declare class Turn {
  /** `0, 1, 2, ...` in order of first appearance. */
  speaker: number;
  /** Seconds from the start of the recording. */
  start: number;
  end: number;
  readonly duration: number;
  toJSON(): { speaker: number; start: number; end: number };
}

/** Who spoke when. */
export declare class Diarization {
  /** Every turn, by start time. Turns of different speakers may overlap. */
  turns: Turn[];
  /** The recording's length in seconds. */
  duration: number;
  /** The distinct speakers heard. */
  speakerCount: number;
  /** The turns of one speaker, by start time. */
  turnsOf(speaker: number): Turn[];
  /** The speakers whose speech adds up to at least `minimumShare` of the recording. A share of 0 keeps everyone. */
  speakers(options?: { minimumShare?: number }): number[];
  /**
   * The same result without the speakers under `minimumShare` of the recording:
   * their turns are gone and the rest are numbered by first appearance again.
   */
  keepingSpeakers(options: { minimumShare: number }): Diarization;
  toJSON(): object;
  /** A result stored with `JSON.stringify`, restored. */
  static fromJSON(json: string | object): Diarization;
}

/**
 * How the model is loaded, from `@desert-ant-labs/core`: `directory` (Node) or
 * `modelBaseUrl` (browser) adopt self-hosted files, `onProgress` reports the
 * download, and the `litert*` / `accelerator` options tune the browser runtime.
 */
export type LoadOptions = ModelLoadOptions;

/**
 * On-device speaker diarization for JavaScript. The default `@desert-ant-labs/who`
 * import is the browser WebAssembly + LiteRT.js build and is safe to import
 * during server-side rendering; for server-side inference in Node import
 * `@desert-ant-labs/who/native` from server-only code. Both expose this same API.
 *
 * ```ts
 * const who = await Who.load();
 * const result = await who.diarize(file);
 * for (const turn of result.turns) console.log(turn.speaker, turn.start, turn.end);
 * ```
 */
export declare class Who {
  /** Use Who.load(); the constructor is internal. */
  private constructor();
  /**
   * Load the model and return a ready instance. Downloads from Hugging Face at
   * the pinned revision and caches by default; pass `directory` (Node) or
   * `modelBaseUrl` (browser) to adopt self-hosted files instead.
   */
  static load(options?: LoadOptions): Promise<Who>;
  /** Who spoke when. */
  diarize(input: AudioInput, options?: DiarizeOptions): Promise<Diarization>;
  /** Send recorded usage and await the POST. */
  flushTelemetry(): Promise<boolean>;
  /** Whether the model is usable with no network. */
  isDownloaded(): boolean;
  /**
   * Run `body` with a fresh call-group id, so every `diarize({ group })`
   * inside it bills as a single usage call.
   */
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  /** Release the model. The instance is unusable afterwards. */
  dispose(): void;
}
