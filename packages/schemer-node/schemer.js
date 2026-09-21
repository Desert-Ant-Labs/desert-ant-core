// Schemer's public API, over whichever core the entry point bound: the
// browser's WebAssembly + LiteRT.js core (browser.js) or the prebuilt native
// core (node.js). Both expose the same ABI, and @desert-ant-labs/core turns
// either one into the same `LoadedModel`, so the API is written once here
// instead of once per runtime.
import {
  decodeExtraction, encodeInput, encodeOptions, normalizeSchema, validateSchema,
} from "./codec.js";

export { TRUNCATED } from "./codec.js";

/**
 * Build the `Schemer` class over a bound SDK (`createWasmSdk` /
 * `createNativeSdk`). The entry points do nothing but call this.
 */
export function makeSchemer(sdk) {
  /**
   * On-device structured extraction: free text plus a schema, typed JSON out.
   * Create one with `await Schemer.load(...)` and reuse it, mirroring the
   * Swift SDK.
   *
   * ```js
   * const schemer = await Schemer.load();
   * const out = await schemer.extract("Coffee at Blue Bottle, $18.50", {
   *   merchant: { type: "string", describe: "the shop or vendor" },
   *   amount:   { type: "number", describe: "total paid" },
   *   urgent:   "boolean",
   * });
   * // { merchant: "Blue Bottle", amount: 18.5, urgent: null }
   * schemer.dispose();
   * ```
   *
   * Nothing is generated. Every field is decoded by a head built for its type,
   * so the result is typed by construction: extracted strings are always
   * substrings of the input, labels are always one of the values you declared,
   * and a field the text does not state comes back `null` rather than
   * invented.
   */
  return class Schemer {
    #model;
    constructor(model) { this.#model = model; }

    /**
     * Load the model and return a ready extractor. By default the model is
     * downloaded from the Hugging Face Hub at the pinned revision, verified,
     * and cached (the filesystem under Node, the runtime's cache in the
     * browser); `onProgress` reports the fraction. Pass `directory` (Node) or
     * `modelBaseUrl` (browser) to use files you host yourself. The repo and
     * revision are pinned to the SDK.
     */
    static async load(options = {}) {
      return new Schemer(await sdk.open(options));
    }

    /**
     * Extract every field in `schema` from `text`.
     *
     * `schema` is either an object keyed by field name or an array of
     * `{name, type, ...}`. A field is `{type, describe?, nullable?}`, or just
     * the type string. `type` is one of `string`, `number`, `boolean`,
     * `datetime`, `label`, `array`; a `label` field also needs `values` (at
     * most 16), and a `number` field may carry `min`, `max` and `unit`.
     *
     * `describe` is read by the model, not ignored: it conditions the
     * encoding, so it is worth writing well ("the shop or vendor" beats
     * "merchant name").
     *
     * `options.now` (a Date or `YYYY-MM-DD`) is the date relative expressions
     * resolve against; it defaults to the device clock. `options.deviceId`
     * attributes usage to a specific end-user device; `options.group` (an id
     * from {@link withCallGroup}) bills several calls as one.
     */
    /**
     * Throw the `TypeError` `extract` would for a schema the runtime cannot
     * honor. Needs no model, so a schema can be checked before a download.
     */
    static validate(schema) {
      validateSchema(normalizeSchema(schema));
    }

    async extract(text, schema, options = {}) {
      const fields = validateSchema(normalizeSchema(schema));
      if (fields.length === 0) return {};
      const r = await this.#model.run(
        encodeInput(text, fields),
        encodeOptions({ now: options.now }),
        options);
      return decodeExtraction(r, fields);
    }

    /**
     * Send the usage recorded so far and await the POST, so a short-lived
     * process (a CLI, a Lambda) does not exit before it lands. Usage is
     * reported on its own otherwise; such a process has no idle gap for the
     * debounce to fire in.
     */
    flushTelemetry() { return this.#model.flushTelemetry(); }

    /** Whether the model is usable with no network. */
    isDownloaded() { return this.#model.isDownloaded(); }

    /**
     * Run `body(group)` with a fresh call-group id, so every
     * `extract(..., { group })` inside it bills as a single usage call. One
     * `extract` is already one call, however many fields it has.
     */
    withCallGroup(body) { return this.#model.withCallGroup(body); }

    /** Release the model. The extractor is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}
