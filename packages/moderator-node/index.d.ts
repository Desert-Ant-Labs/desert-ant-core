// The model-specific half of this package's types. Everything that is the same
// for every model - how a model is loaded, how a call is billed and attributed -
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions, ModelLoadOptions } from "@desert-ant-labs/core";

/**
 * Decoded pixels: `width * height` RGB or RGBA bytes, row-major from the
 * top-left. An `ImageData` satisfies it. Alpha is ignored.
 */
export interface Pixels {
  data: Uint8Array | Uint8ClampedArray | ArrayLike<number>;
  width: number;
  height: number;
}

/**
 * Anything `analyze` takes: raw {@link Pixels} everywhere, and in the browser
 * whatever `createImageBitmap` accepts.
 */
export type ImageInput = Pixels | ImageBitmapSource;

/** Per-region confidences in `[0, 1]`, each the max over the scored crops. */
export interface Regions {
  nipples: number;
  genitals: number;
  buttocks: number;
  nude: number;
  sexAct: number;
}

/** The result of analyzing one image. */
export interface Moderation {
  /** The NSFW score in `[0, 1]` under the requested policy. */
  score: number;
  /** Whether `score` meets the threshold. */
  isNSFW: boolean;
  /** Per-region detail, for custom policies and UI. */
  regions: Regions;
}

/** Options for a single `analyze` call. */
export interface AnalyzeOptions extends CallOptions {
  /** Score at or above which `isNSFW` is true. Default `0.5`. */
  threshold?: number;
  /**
   * Which heads count toward the score. `"standard"` (default) flags any nudity
   * including a bare chest; `"allowTopless"` ignores a bare chest alone.
   */
  policy?: "standard" | "allowTopless";
  /**
   * Crops scored per image: `"fast"` one center crop (video), `"balanced"` four
   * multiscale tiles, `"accurate"` (default) those tiles and their mirrors.
   */
  quality?: "fast" | "balanced" | "accurate";
}

/**
 * How the model is loaded, from `@desert-ant-labs/core`: `directory` (Node) or
 * `modelBaseUrl` (browser) adopt self-hosted files, `onProgress` reports the
 * download, and the `litert*` / `accelerator` options tune the browser runtime.
 */
export type LoadOptions = ModelLoadOptions;

/**
 * On-device NSFW image detection for JavaScript. The default
 * `@desert-ant-labs/moderator` import is the browser WebAssembly + LiteRT.js
 * build and is safe to import during server-side rendering; for server-side
 * inference in Node import `@desert-ant-labs/moderator/native` from
 * server-only code. Both expose this same API.
 *
 * ```ts
 * const moderator = await Moderator.load();
 * const { score, isNSFW } = await moderator.analyze(imageData);
 * ```
 */
export declare class Moderator {
  /** Use Moderator.load(); the constructor is internal. */
  private constructor();
  /**
   * Load the model and return a ready moderator. Downloads from the Hugging
   * Face Hub at the pinned revision and caches by default; pass `directory`
   * (Node) or `modelBaseUrl` (browser) to adopt self-hosted files instead.
   */
  static load(options?: LoadOptions): Promise<Moderator>;
  /** Score an image for nudity or sexual activity. */
  analyze(image: ImageInput, options?: AnalyzeOptions): Promise<Moderation>;
  /** Send recorded usage and await the POST. One load per device per call. */
  flushTelemetry(): Promise<boolean>;
  /** Whether the model is usable with no network. */
  isDownloaded(): boolean;
  /**
   * Run `body` with a fresh call-group id, so every `analyze({ group })`
   * inside it bills as a single usage call.
   */
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  /** Release the model. The moderator is unusable afterwards. */
  dispose(): void;
}
