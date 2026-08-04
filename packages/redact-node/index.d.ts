/** The 20 model labels plus the deterministic-only `IMEI` label. */
export type RedactLabel =
  | "GIVEN_NAME" | "SURNAME" | "STREET_NAME" | "BUILDING_NUMBER" | "SECONDARY_ADDRESS"
  | "CITY" | "STATE" | "ZIP_CODE" | "EMAIL" | "PHONE" | "CREDIT_CARD" | "BANK_ACCOUNT"
  | "ROUTING_NUMBER" | "IP_ADDRESS" | "URL" | "GOVERNMENT_ID" | "PASSPORT"
  | "DRIVERS_LICENSE" | "TAX_ID" | "SSN" | "IMEI";

/** A single redacted entity, with its placeholder and original value. */
export interface RedactionItem {
  /** PII category, e.g. `"EMAIL"`. */
  label: string;
  /** The matched sensitive text. */
  original: string;
  /** Numbered placeholder, e.g. `"[EMAIL_1]"`. */
  placeholder: string;
  /** Confidence in `0..1` (deterministic recognizers report `1`). */
  confidence: number;
  /** Character offsets of `original` in the source text. */
  start: number;
  end: number;
}

/** The result of a redaction: masked text, the detections, and a restore helper. */
export interface Redaction {
  /** The input with every detection replaced by a `[LABEL_N]` placeholder. */
  redactedText: string;
  /** Every detection, in document order. */
  items: RedactionItem[];
  /** Fill original values back into text that still contains the placeholders. */
  restore(processed: string): string;
}

/** Detection options. */
export interface Options {
  /** Neural confidence threshold, `0..1`. Default `0.6`. Deterministic recognizers always apply. */
  minimumConfidence?: number;
  /** Restrict detection to these labels. Omit to detect every category. */
  labels?: Iterable<string>;
}

/**
 * How the model is loaded. The repo and revision are pinned to the SDK. By
 * default the model is downloaded from the Hugging Face Hub at the pinned tag
 * and cached (nothing is bundled in the npm package); use `directory` (Node) or
 * `modelBaseUrl` (browser) to self-host / run offline.
 */
export interface LoadOptions {
  /**
   * An explicit directory that is this model's home (Node): if it already holds
   * the files they are used offline, otherwise the model is downloaded into it.
   * Omit to download from the Hub into the managed cache
   * (`~/.cache/desert-ant-models/...`).
   */
  directory?: string;
  /**
   * Base URL of self-hosted model files, e.g. `"/assets/redact/"` or
   * `"https://cdn.example.com/redact/"` (browser). When set, the files load
   * from there instead of the Hugging Face Hub. Browser only.
   */
  modelBaseUrl?: string;
  /** Download progress in `[0, 1]`, called during {@link Redact.load}. */
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
 * On-device multilingual PII redaction for JavaScript. The default
 * `@desert-ant-labs/redact` import is the browser WebAssembly + LiteRT.js build:
 * it has no native dependencies, so it builds cleanly for every target of a
 * multi-target bundler (Next, Remix, SvelteKit, Nuxt) and is safe to import
 * during server-side rendering. LiteRT.js initializes only in a browser or Web
 * Worker, so `Redact.load()` runs inference in the browser; in plain Node it
 * throws and directs you to the native build. For server-side inference in Node
 * import `@desert-ant-labs/redact/native` (a prebuilt native core, no
 * `@litertjs/core`) from server-only code. Both expose this same `Redact` API.
 * Create one with `await Redact.load(...)` and reuse it.
 *
 * ```ts
 * const redact = await Redact.load();
 * const r = await redact.redaction("Email Anna at anna@example.com.");
 * r.redactedText; r.items; r.restore(reply);
 * ```
 */
export declare class Redact {
  /**
   * Load the model and return a ready redactor. By default it downloads from the
   * Hugging Face Hub at the pinned tag on first call, verifies it (SHA-256), and
   * caches it (nothing model-sized ships in the npm package). Pass `directory`
   * (Node) or `modelBaseUrl` (browser) to self-host / run offline instead.
   */
  static load(options?: LoadOptions): Promise<Redact>;
  /**
   * Detect and redact the PII in `text`. Each entity is replaced by a unique,
   * numbered placeholder (`[EMAIL_1]`, `[GIVEN_NAME_1]`, ...) so the result is
   * safe to hand to an LLM and restore afterwards via {@link Redaction.restore}.
   */
  redaction(text: string, options?: Options): Promise<Redaction>;
  /** Free native resources (the `@desert-ant-labs/redact/native` build). No-op in
   * the default WebAssembly build. Safe to call in both. */
  dispose(): void;
}
