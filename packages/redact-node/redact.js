// Redact's public API, written once over whichever core the entry point bound
// (browser.js's WebAssembly core or node.js's native core); @desert-ant-labs/core
// turns either into the same `LoadedModel`.
import { decodeRedaction, encodeInput, encodeOptions } from "./codec.js";

/** Every label the model can emit, including `ORG`. */
export const ALL_LABELS = Object.freeze([
  "GIVEN_NAME", "SURNAME", "STREET_NAME", "BUILDING_NUMBER", "SECONDARY_ADDRESS",
  "CITY", "STATE", "ZIP_CODE", "EMAIL", "PHONE", "CREDIT_CARD", "BANK_ACCOUNT",
  "ROUTING_NUMBER", "IP_ADDRESS", "URL", "GOVERNMENT_ID", "PASSPORT",
  "DRIVERS_LICENSE", "TAX_ID", "SSN", "IMEI", "ORG",
]);

/**
 * Redacted when `options.labels` is omitted: everything except `ORG`, since a
 * company is not a natural person. Opt in with
 * `{ labels: [...DEFAULT_LABELS, "ORG"] }`.
 */
export const DEFAULT_LABELS = Object.freeze(ALL_LABELS.filter((l) => l !== "ORG"));

/**
 * Build the `Redact` class over a bound SDK (`createWasmSdk` /
 * `createNativeSdk`).
 */
export function makeRedact(sdk) {
  /**
   * On-device multilingual PII redaction. Create one with
   * `await Redact.load(...)` and reuse it, mirroring the iOS/Swift SDK.
   *
   * ```js
   * const redact = await Redact.load();               // download on demand, cached
   * const r = await redact.redaction("Email Anna at anna@example.com.");
   * r.redactedText; r.items; r.restore(reply);
   * redact.dispose();
   * ```
   */
  return class Redact {
    #model;
    constructor(model) { this.#model = model; }

    /**
     * Load the model and return a ready redactor. By default the model is
     * downloaded from the Hugging Face Hub at the pinned revision, verified, and
     * cached (the filesystem under Node, the runtime's cache in the browser).
     * Pass `directory` (Node) or `modelBaseUrl` (browser) to use files you host
     * yourself. The repo and revision are pinned to the SDK.
     */
    static async load(options = {}) {
      return new Redact(await sdk.open(options));
    }

    /**
     * Detect and redact the PII in `text`. Each entity is replaced by a unique,
     * numbered placeholder (`[EMAIL_1]`, ...), safe to hand to an LLM and
     * restore afterwards via the returned `restore`.
     *
     * `options.deviceId` (a string or a zero-arg function returning one)
     * attributes usage to a specific end-user device; it is collected per call,
     * so it is safe for concurrent multi-tenant hosts. `options.group` (an id
     * from {@link withCallGroup}) bills several calls as one.
     */
    async redaction(text, options = {}) {
      const payload = encodeOptions({
        minimumConfidence: options.minimumConfidence ?? 0.6,
        labels: Array.from(options.labels ?? DEFAULT_LABELS),
      });
      return decodeRedaction(
        await this.#model.run(encodeInput(String(text ?? "")), payload, options));
    }

    /** Whether the model is usable with no network. */
    isDownloaded() { return this.#model.isDownloaded(); }

    /**
     * Run `body(group)` with a fresh call-group id, so every
     * `redaction({ group })` inside it bills as a single usage call. The group
     * is released when `body` settles.
     */
    withCallGroup(body) { return this.#model.withCallGroup(body); }

    /**
     * Send the usage recorded so far and await the POST, so a short-lived process
     * (a CLI, a Lambda) does not exit before it lands. Usage is reported on its own
     * otherwise; such a process has no idle gap for the debounce to fire in.
     */
    flushTelemetry() { return this.#model.flushTelemetry(); }

    /** Release the model. The redactor is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}
