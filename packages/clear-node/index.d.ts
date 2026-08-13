// The model-specific half of this package's types. Everything that is the same
// for every model - how a model is loaded, how a call is billed and attributed -
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions, ModelLoadOptions } from "@desert-ant-labs/core";

/** The delivery targets Clear ships presets for, in integrated LUFS. */
export declare const LOUDNESS_PRESETS: {
  readonly applePodcasts: -19;
  readonly podcast: -19;
  readonly spotify: -14;
  readonly youtube: -14;
  readonly broadcast: -23;
};

/** A key of {@link LOUDNESS_PRESETS}. */
export type LoudnessPreset = keyof typeof LOUDNESS_PRESETS;

/** The enhanced audio, and what mastering measured on the way out. */
export interface ClearResult {
  /** Enhanced audio, one entry per channel. Mono input gives one. */
  channels: Float32Array[];
  /** The first channel - the whole signal for mono, the left of a stereo pair. */
  samples: Float32Array;
  /** How many entries `channels` holds. */
  channelCount: number;
  /** The delivery rate, 48000 unless `outputSampleRate` asked otherwise. */
  sampleRate: number;
  /** Length of the output in seconds. */
  durationSec: number;
  /** Wall-clock time the enhance took. */
  processingSec: number;
  /** Integrated loudness of the *input*, or null when mastering was bypassed. */
  measuredLUFS: number | null;
  /**
   * True peak of the delivered audio in dBFS (4x oversampled), or null when
   * mastering was bypassed. Measured after limiting, so it is what to assert a
   * delivery spec against.
   */
  measuredTruePeakDBFS: number | null;
  /** `durationSec / processingSec`: above 1 is faster than real time. */
  readonly realtimeFactor: number;
}

export interface EnhanceOptions extends CallOptions {
  /** Enhancement blend in `0..1`. 1 (default) is the full model output. */
  strength?: number;
  /**
   * Integrated-LUFS target, a {@link LoudnessPreset} name, or null to skip
   * mastering and return the model's own level. Defaults to `"applePodcasts"`.
   */
  targetLUFS?: number | LoudnessPreset | null;
  /** True-peak ceiling in dBTP. Defaults to -1.5. */
  peakCeilingDBFS?: number;
  /** Upper bound on the loudness gain in dB. Defaults to 9. */
  maxGainDB?: number;
  /** Delivery sample rate. The model always runs at 48 kHz; the result is
   *  resampled on the way out. Defaults to 48000. */
  outputSampleRate?: number;
  /**
   * What the output's channel layout should be. `"mono"` (the default)
   * downmixes before enhancement and emits one channel, which is what every
   * release so far did; `"preserve"` keeps the input's layout and costs an
   * inference pass per channel.
   */
  channelMode?: "mono" | "preserve";
  /** Per-channel LUFS target applied before the joint stages, to correct a pair
   *  whose sides were recorded at different levels. Omit to leave the balance
   *  alone; mastering is otherwise joint and never moves the stereo image. */
  balanceChannelsLUFS?: number;
}

/** On-device speech enhancement: denoise, dereverb, loudness-normalize. */
export declare class Clear {
  /** Load the model, downloading and caching it on first use. */
  static load(options?: ModelLoadOptions): Promise<Clear>;
  /**
   * Enhance audio. Pass one run of samples for mono, or one entry per channel
   * for multi-channel - the output is mono unless `channelMode` is
   * `"preserve"`.
   */
  enhance(samples: Float32Array | number[] | Float32Array[] | number[][],
          sampleRate?: number, options?: EnhanceOptions): Promise<ClearResult>;
  /** Whether the model is usable with no network. */
  isDownloaded(): boolean;
  /** Bill every call made inside `body` as one usage call. */
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  /** Release the model. */
  dispose(): void;
}
