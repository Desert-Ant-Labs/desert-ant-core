// The model-specific half of this package's types. Everything that is the same
// for every model - how a model is loaded, how a call is billed and attributed -
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions, ModelLoadOptions } from "@desert-ant-labs/core";

/** The field kinds a schema can declare. */
export type FieldType =
  | "string" | "number" | "boolean" | "datetime" | "label" | "array";

/** One field to extract. */
export interface FieldSpec {
  type: FieldType;
  /**
   * A short natural-language hint. Read by the model, not ignored: it
   * conditions the encoding, so it is worth writing well.
   */
  describe?: string;
  /**
   * Whether absence is an expected answer. Set to true, a number may come back
   * null (otherwise it composes a value), and the number and datetime heads are
   * told absence is expected, which moves their decisions: so setting it is not
   * the same as leaving it unset.
   */
  nullable?: boolean;
  /** Required when `type` is `"label"`. At most 16 values. */
  values?: string[];
  /** Number fields: the inclusive range. A value outside it is clamped, and
   *  the range is read by the number head. */
  min?: number;
  max?: number;
  /** Number fields: a unit hint ("currency", "kg", "hour"), read by the
   *  number head. */
  unit?: string;
  /**
   * An array of objects, in JSON Schema's spelling: `type: "array"` with
   * `items: { type: "object", properties }`. The text is split into candidate
   * items and the properties are extracted from each, so it works where each
   * item has its own clause or list entry. Properties cannot themselves be
   * arrays of objects.
   */
  items?: { type: "object"; properties: Schema };
}

/** A field in array form, where order is explicit. */
export interface NamedField extends FieldSpec {
  name: string;
}

/**
 * A schema: either an object keyed by field name, or an ordered array. A field
 * may be given as just its type string.
 *
 *     { merchant: { type: "string", describe: "the shop or vendor" },
 *       amount:   "number" }
 */
export type Schema =
  | Record<string, FieldSpec | FieldType>
  | NamedField[];

/**
 * One extracted value. `null` is a real answer: it means the text did not
 * state the field, which is the case the model is built to detect.
 */
export type Value = string | number | boolean | string[] | Item[] | null;

/** One item of an array of objects: only the properties the text states. */
export type Item = Record<string, string | number | boolean | string[]>;

/**
 * Set to `true` on an extraction whose text was longer than the model reads
 * (about 1,216 tokens with the schema), so its end was never seen. A symbol,
 * so it never collides with a field name and stays out of JSON.
 */
export declare const TRUNCATED: unique symbol;

/** Field name to value, in schema order. */
export type Extraction = Record<string, Value> & { [TRUNCATED]?: true };

export interface ExtractOptions extends CallOptions {
  /**
   * The date relative expressions ("tomorrow at 9:30") resolve against, as a
   * Date or `YYYY-MM-DD`. Defaults to the device clock; pin it for
   * reproducible results. The model never learns date arithmetic - the
   * runtime hands it `today=YYYY-MM-DD` and the datetime head decodes an
   * offset from it.
   */
  now?: Date | string;
}

/**
 * On-device structured extraction for JavaScript: free text plus a schema,
 * typed values out. The default `@desert-ant-labs/schemer` import is the
 * browser WebAssembly + LiteRT.js build and is safe to import during
 * server-side rendering; for server-side inference in Node import
 * `@desert-ant-labs/schemer/native` from server-only code. Both expose this
 * same API.
 *
 * Nothing is generated. Every field is decoded by a head built for its type,
 * so the result is typed by construction: extracted strings are always
 * substrings of the input, labels are always one of the values you declared,
 * and a field the text does not state comes back `null` rather than invented.
 *
 * ```ts
 * const schemer = await Schemer.load();
 * const out = await schemer.extract("Coffee at Blue Bottle, $18.50", {
 *   merchant: { type: "string", describe: "the shop or vendor" },
 *   amount: { type: "number", unit: "currency" },
 * });
 * ```
 */
export declare class Schemer {
  /** Use Schemer.load(); the constructor is internal. */
  private constructor();
  /**
   * Load the model and return a ready extractor. Downloads from the Hugging
   * Face Hub at the pinned revision and caches by default; pass `directory`
   * (Node) or `modelBaseUrl` (browser) to adopt self-hosted files instead.
   */
  static load(options?: ModelLoadOptions): Promise<Schemer>;
  /** Throw the TypeError `extract` would for a schema the runtime cannot
   *  honor. Needs no model, so a schema can be checked before a download. */
  static validate(schema: Schema): void;
  /** Extract every field in `schema` from `text`, in schema order. One call
   *  is one billed usage call, however many fields it has. */
  extract(text: string, schema: Schema, options?: ExtractOptions): Promise<Extraction>;
  /** Send recorded usage and await the POST. One load per device per call. */
  flushTelemetry(): Promise<boolean>;
  /** Whether the model is usable with no network. */
  isDownloaded(): boolean;
  /** Bill every call made inside `body` as one usage call. */
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  /** Release the model. The extractor is unusable afterwards. */
  dispose(): void;
}

/** The compiled label graph takes at most this many candidate values. */
export declare const MAX_LABEL_VALUES: 16;
