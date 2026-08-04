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
export interface SuggestOptions {
  /** Maximum number of suggestions to return (default `3`). */
  limit?: number;
  /** Preferred skin tone for skin-tone-capable emoji (default `"default"`). */
  skinTone?: EmojiSkinTone;
  /**
   * Attributes usage to a specific end-user device (multi-tenant hosts serving
   * many users). A string, or a zero-arg function returning one, collected per
   * call and bound to that call so it is safe under concurrency. Omit to use
   * the default device. Honored by both the WebAssembly and native Node builds.
   */
  deviceId?: string | (() => string);
  /**
   * Bills this call as part of a shared usage call group, so a logical operation
   * made of several suggestions counts once. Get an id from
   * {@link Emo.withCallGroup}. Native Node build only.
   */
  group?: string;
}

/**
 * How the model is loaded. By default the model is downloaded from the Hugging
 * Face Hub at the pinned revision and cached (filesystem on Node, Cache API /
 * IndexedDB in the browser). The repo and revision are pinned to the SDK. Use
 * `directory` (Node) or `modelBaseUrl` (browser) to self-host / run offline.
 */
export interface LoadOptions {
  /**
   * Adopt self-hosted model files from an explicit directory (Node) instead of
   * downloading from the Hugging Face Hub. If the folder already holds the files
   * they are used offline; otherwise the model is downloaded into it. Omit to
   * download into the managed cache (`~/.cache/desert-ant-models/...`).
   */
  directory?: string;
  /**
   * Adopt self-hosted model files from a base URL (browser) instead of
   * downloading from the Hugging Face Hub, e.g. `"/assets/emo/"`. Files are
   * fetched from `${modelBaseUrl}/<file>`; use this for offline / no-runtime-CDN
   * setups. Omit to download from the Hub and cache in Cache API / IndexedDB.
   */
  modelBaseUrl?: string;
  /** Download progress in `[0, 1]`, called during {@link Emo.load}. */
  onProgress?: (fraction: number) => void;
  /** Base directory for the managed cache (Node, server-side). Defaults to
   * `~/.cache`. Ignored in the browser. */
  cacheRoot?: string;
  /** Bring-your-own LiteRT.js module (the `@litertjs/core` namespace). Browser only. */
  litert?: unknown;
  /** URL/path to the LiteRT.js Wasm directory (defaults: installed package in
   * node, jsDelivr CDN in the browser). */
  litertWasmDir?: string;
  /** LiteRT.js accelerator: `"wasm"` (XNNPACK CPU, default), `"webgpu"`, or `"webnn"`. */
  accelerator?: "wasm" | "webgpu" | "webnn";
}

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
   * settles. Native Node build only.
   */
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  /** Free native resources (the `@desert-ant-labs/emo/native` build). No-op in
   * the default WebAssembly build. Safe to call in both. */
  dispose(): void;
}
