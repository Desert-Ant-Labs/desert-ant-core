// The model-specific half of this package's types. Everything that is the same
// for every model - how a model is loaded, how a call is billed and attributed -
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions, ModelLoadOptions } from "@desert-ant-labs/core";

/** The model labels, the deterministic-only `IMEI`, and `ORG`. */
export type RedactLabel =
  | "GIVEN_NAME" | "SURNAME" | "STREET_NAME" | "BUILDING_NUMBER" | "SECONDARY_ADDRESS"
  | "CITY" | "STATE" | "ZIP_CODE" | "EMAIL" | "PHONE" | "CREDIT_CARD" | "BANK_ACCOUNT"
  | "ROUTING_NUMBER" | "IP_ADDRESS" | "URL" | "GOVERNMENT_ID" | "PASSPORT"
  | "DRIVERS_LICENSE" | "TAX_ID" | "SSN" | "IMEI" | "ORG";

/**
 * Redacted when {@link Options.labels} is omitted: every category except `ORG`.
 *
 * ```js
 * await redact.redaction(text, { labels: [...DEFAULT_LABELS, "ORG"] });
 * ```
 */
export declare const DEFAULT_LABELS: readonly RedactLabel[];

/** Every label, including `ORG`. */
export declare const ALL_LABELS: readonly RedactLabel[];

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
export interface Options extends CallOptions {
  /** Neural confidence threshold, `0..1`. Default `0.6`. Deterministic recognizers always apply. */
  minimumConfidence?: number;
  /** Restrict redaction to these labels. Omit for {@link DEFAULT_LABELS}. */
  labels?: Iterable<RedactLabel | string>;
}

/**
 * How the model is loaded, from `@desert-ant-labs/core`: `directory` (Node) or
 * `modelBaseUrl` (browser) adopt self-hosted files, `onProgress` reports the
 * download, and the `litert*` / `accelerator` options tune the browser runtime.
 * Model-agnostic, so it is declared once in core rather than restated per model.
 */
export type LoadOptions = ModelLoadOptions;

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
  /** Use Redact.load(); the constructor is internal. */
  private constructor();
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
  /**
   * Run `body` with a fresh call-group id, so every `redaction({ group })` inside
   * it bills as a single usage call. The group is released when `body` settles.
   */
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  /** Release the model. The redactor is unusable afterwards. Both builds. */
  dispose(): void;
}
