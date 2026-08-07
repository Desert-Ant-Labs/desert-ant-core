// The model-specific half of this package's types. Everything that is the same
// for every model - how a model is loaded, how a call is billed and attributed -
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions, ModelLoadOptions } from "@desert-ant-labs/core";

/** Preferred emoji skin tone for skin-tone-capable emoji. */
export type EmojiSkinTone =
  | "default"
  | "light"
  | "mediumLight"
  | "medium"
  | "mediumDark"
  | "dark";

/** A single emoji suggestion. */
export interface EmoSuggestion {
  /** The suggested emoji. */
  emoji: string;
  /** The model's normalized confidence, from `0` to `1`. */
  confidence: number;
}

/** Options for a single suggestion call. */
export interface SuggestOptions extends CallOptions {
  /** Maximum number of suggestions to return (default `3`). */
  limit?: number;
  /** Preferred skin tone for skin-tone-capable emoji (default `"default"`). */
  skinTone?: EmojiSkinTone;
}

/**
 * How the model is loaded, from `@desert-ant-labs/core`: `directory` (Node) or
 * `modelBaseUrl` (browser) adopt self-hosted files, `onProgress` reports the
 * download, and the `litert*` / `accelerator` options tune the browser runtime.
 * Model-agnostic, so it is declared once in core rather than restated per model.
 */
export type LoadOptions = ModelLoadOptions;

/**
 * On-device multilingual emoji suggestion for JavaScript. The default
 * `@desert-ant-labs/emo` import is the browser WebAssembly + LiteRT.js build: it
 * has no native dependencies, so it builds cleanly for every target of a
 * multi-target bundler (Next, Remix, SvelteKit, Nuxt) and is safe to import
 * during server-side rendering. LiteRT.js initializes only in a browser or Web
 * Worker, so `Emo.load()` runs inference in the browser; in plain Node it throws
 * and directs you to the native build. For server-side inference in Node import
 * `@desert-ant-labs/emo/native` (a prebuilt native core, no `@litertjs/core`)
 * from server-only code. Both expose this same `Emo` API. Create one with
 * `await Emo.load(...)` and reuse it.
 *
 * ```ts
 * const emo = await Emo.load();
 * const suggestions = await emo.suggestions("Pay my bills");   // EmoSuggestion[]
 * ```
 */
export declare class Emo {
  /** Use Emo.load(); the constructor is internal. */
  private constructor();
  /**
   * Load the model and return a ready suggester. Downloads from the Hugging Face
   * Hub at the pinned revision and caches by default; pass `directory` (Node) or
   * `modelBaseUrl` (browser) to adopt self-hosted files instead.
   */
  static load(options?: LoadOptions): Promise<Emo>;
  /**
   * Suggest emojis for `text`, most likely first. Returns up to `limit`
   * suggestions; empty input returns `[]`.
   */
  suggestions(text: string, options?: SuggestOptions): Promise<EmoSuggestion[]>;
  /**
   * Run `body` with a fresh call-group id, so every `suggestions({ group })`
   * inside it bills as a single usage call. The group is released when `body`
   * settles.
   */
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  /** Release the model. The suggester is unusable afterwards. Both builds. */
  dispose(): void;
}
