// Toxic's public API, written once over whichever core the entry point bound
// (browser.js's WebAssembly core or node.js's native core).
import { decodeAnalysis, encodeInput, encodeOptions } from "./codec.js";

/**
 * Build the `Toxic` class over a bound SDK (`createWasmSdk` / `createNativeSdk`).
 */
export function makeToxic(sdk) {
  /**
   * On-device hate-speech triage. Create one with `await Toxic.load()` and
   * reuse it, mirroring the Swift SDK.
   *
   * ```js
   * const toxic = await Toxic.load();
   * const { isToxic, scores, targets } = await toxic.analyze(comment);
   * toxic.dispose();
   * ```
   */
  return class Toxic {
    #model;
    constructor(model) { this.#model = model; }

    /**
     * Load the model and return a ready classifier. By default the model is
     * downloaded from the Hugging Face Hub at the pinned revision, verified, and
     * cached. Pass `directory` (Node) or `modelBaseUrl` (browser) to use files
     * you host yourself.
     */
    static async load(options = {}) {
      return new Toxic(await sdk.open(options));
    }

    /**
     * Score a text: every head's probability, the threshold each was judged at,
     * the heads that fired, and `isToxic` (a content head fired). A text longer
     * than the model's window is read in overlapping windows and each head
     * keeps its highest score.
     *
     * `options.thresholds` maps a label to the threshold that replaces the
     * model's default for that head. `options.deviceId` names the end-user
     * device for the call; licensing does not read it yet. `options.group` has
     * no effect.
     */
    async analyze(text, options = {}) {
      return decodeAnalysis(
        await this.#model.run(encodeInput(text), encodeOptions(options), options));
    }

    /**
     * Wait for the license requests in flight, so a short-lived process (a CLI,
     * a Lambda) does not exit before they finish.
     */
    flushTelemetry() { return this.#model.flushTelemetry(); }

    /** Whether the model is usable with no network. */
    isDownloaded() { return this.#model.isDownloaded(); }

    /** @deprecated Has no effect: runs `body` with a group id that nothing reads. */
    withCallGroup(body) { return this.#model.withCallGroup(body); }

    /** Release the model. The classifier is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}
