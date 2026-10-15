// Emo's public API, written once over whichever core the entry point bound
// (browser.js's WebAssembly core or node.js's native core); @desert-ant-labs/core
// turns either into the same `LoadedModel`.
import { decodeSuggestions, encodeInput, encodeOptions, SKIN_TONES } from "./codec.js";

/**
 * Build the `Emo` class over a bound SDK (`createWasmSdk` / `createNativeSdk`).
 */
export function makeEmo(sdk) {
  /**
   * On-device multilingual emoji suggestion. Create one with
   * `await Emo.load(...)` and reuse it, mirroring the iOS/Swift SDK.
   *
   * ```js
   * const emo = await Emo.load();                 // downloads the model on first use, cached
   * const suggestions = await emo.suggestions("Pay my bills");  // [{ emoji, confidence }, ...]
   * emo.dispose();
   * ```
   */
  return class Emo {
    #model;
    constructor(model) { this.#model = model; }

    /**
     * Load the model and return a ready suggester. By default the model is
     * downloaded from the Hugging Face Hub at the pinned revision, verified, and
     * cached (the filesystem under Node, the runtime's cache in the browser).
     * Pass `directory` (Node) or `modelBaseUrl` (browser) to use files you host
     * yourself. The repo and revision are pinned to the SDK.
     */
    static async load(options = {}) {
      return new Emo(await sdk.open(options));
    }

    /**
     * Suggest emojis for a phrase, most likely first. Returns up to `limit`
     * `{ emoji, confidence }` suggestions; empty input returns `[]`.
     *
     * `options.deviceId` (a string or a zero-arg function returning one) names
     * the end-user device for the call; licensing does not read it yet.
     * `options.group` has no effect.
     */
    async suggestions(text, options = {}) {
      const phrase = String(text ?? "");
      if (phrase.trim() === "") return [];
      const payload = encodeOptions({
        limit: options.limit ?? 3,
        skinTone: SKIN_TONES[options.skinTone ?? "default"] ?? 0,
      });
      return decodeSuggestions(
        await this.#model.run(encodeInput(phrase), payload, options));
    }

    /** Whether the model is usable with no network. */
    isDownloaded() { return this.#model.isDownloaded(); }

    /** @deprecated Has no effect: runs `body` with a group id that nothing reads. */
    withCallGroup(body) { return this.#model.withCallGroup(body); }

    /**
     * Wait for the license requests in flight, so a short-lived process (a CLI,
     * a Lambda) does not exit before they finish.
     */
    flushTelemetry() { return this.#model.flushTelemetry(); }

    /** Release the model. The suggester is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}
