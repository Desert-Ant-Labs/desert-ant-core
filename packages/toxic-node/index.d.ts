// The model-specific half of this package's types. Everything that is the same
// for every model, such as how a model is loaded and its per-call options,
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions, ModelLoadOptions } from "@desert-ant-labs/core";

/** The three heads that say what a text does. */
export type ContentLabel = "HATEFUL" | "ABUSIVE" | "THREAT";

/** The eight heads that say which group a hateful text is about. */
export type TargetLabel =
  | "RACE" | "RELIGION" | "NATIONAL_ETHNIC_ORIGIN" | "SEXUAL_ORIENTATION"
  | "GENDER" | "DISABILITY" | "AGE" | "OTHER";

export type Label = ContentLabel | TargetLabel;

export declare const CONTENT_LABELS: readonly ContentLabel[];
export declare const TARGET_LABELS: readonly TargetLabel[];
export declare const LABELS: readonly Label[];

/** The result of analyzing one text. */
export interface Analysis {
  /** Every head's probability in `[0, 1]`. */
  scores: Record<Label, number>;
  /** The threshold each head was judged at. */
  thresholds: Record<Label, number>;
  /** The heads at or above their thresholds, content and target heads alike. */
  flagged: Label[];
  /** The content heads that fired, in `CONTENT_LABELS` order. */
  content: ContentLabel[];
  /** The target heads that fired, highest score first. Meaningful when `HATEFUL` fired. */
  targets: TargetLabel[];
  /** Whether any content head fired: the text is hateful, abusive or threatening at the thresholds. */
  isToxic: boolean;
}

/** Options for a single `analyze` call. */
export interface AnalyzeOptions extends CallOptions {
  /**
   * Thresholds that replace the model's defaults for the heads named; a head at
   * or above its threshold is flagged. The defaults ship with the model.
   */
  thresholds?: Partial<Record<Label, number>>;
}

/**
 * How the model is loaded, from `@desert-ant-labs/core`: `directory` (Node) or
 * `modelBaseUrl` (browser) adopt self-hosted files, `onProgress` reports the
 * download, and the `litert*` / `accelerator` options tune the browser runtime.
 */
export type LoadOptions = ModelLoadOptions;

/**
 * On-device hate-speech triage for JavaScript. The default
 * `@desert-ant-labs/toxic` import is the browser WebAssembly + LiteRT.js build
 * and is safe to import during server-side rendering; for server-side inference
 * in Node import `@desert-ant-labs/toxic/native` from server-only code. Both
 * expose this same API.
 *
 * ```ts
 * const toxic = await Toxic.load();
 * const { isToxic, scores, targets } = await toxic.analyze(comment);
 * ```
 */
export declare class Toxic {
  /** Use Toxic.load(); the constructor is internal. */
  private constructor();
  /**
   * Load the model and return a ready classifier. Downloads from Hugging Face
   * at the pinned revision and caches by default; pass `directory` (Node) or
   * `modelBaseUrl` (browser) to adopt self-hosted files instead.
   */
  static load(options?: LoadOptions): Promise<Toxic>;
  /** Score a text for hate, abuse and threats, and for the group it targets. */
  analyze(text: string, options?: AnalyzeOptions): Promise<Analysis>;
  /** Wait for the license requests in flight. */
  flushTelemetry(): Promise<boolean>;
  /** Whether the model is usable with no network. */
  isDownloaded(): boolean;
  /** @deprecated Has no effect: runs `body` with a group id that nothing reads. */
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  /** Release the model. The classifier is unusable afterwards. */
  dispose(): void;
}
