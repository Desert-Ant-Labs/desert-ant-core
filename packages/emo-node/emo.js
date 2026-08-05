// Emo's public API, over whichever core the entry point bound: the browser's
// WebAssembly + LiteRT.js core (browser.js) or the prebuilt native core
// (node.js). Both expose the same ABI, and @desert-ant-labs/core turns either
// one into the same `LoadedModel`, so the API is written once here instead of
// once per runtime.
import { decodeSuggestions, encodeOptions, SKIN_TONES } from "./codec.js";

/**
 * Build the `Emo` class over a bound SDK (`createWasmSdk` / `createNativeSdk`).
 * The entry points do nothing but call this.
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
     * `options.deviceId` (a string or a zero-arg function returning one)
     * attributes usage to a specific end-user device; it is collected per call,
     * so it is safe for concurrent multi-tenant hosts. `options.group` (an id
     * from {@link withCallGroup}) bills several calls as one.
     */
    async suggestions(text, options = {}) {
      const phrase = String(text ?? "");
      if (phrase.trim() === "") return [];
      const payload = encodeOptions({
        limit: options.limit ?? 3,
        skinTone: SKIN_TONES[options.skinTone ?? "default"] ?? 0,
      });
      return decodeSuggestions(await this.#model.run(phrase, payload, options));
    }

    /** Whether the model is usable with no network. */
    isDownloaded() { return this.#model.isDownloaded(); }

    /**
     * Run `body(group)` with a fresh call-group id, so every
     * `suggestions({ group })` inside it bills as a single usage call. The group
     * is released when `body` settles.
     */
    withCallGroup(body) { return this.#model.withCallGroup(body); }

    /** Release the model. The suggester is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}
