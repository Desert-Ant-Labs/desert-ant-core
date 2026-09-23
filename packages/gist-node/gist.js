// Gist's public API, written once over whichever core the entry point bound
// (browser.js's WebAssembly core or node.js's native core); @desert-ant-labs/core
// turns either into the same `LoadedModel`.
import { decodeTagged, encodeInput } from "./codec.js";

/**
 * Build the `Gist` class over a bound SDK (`createWasmSdk` / `createNativeSdk`).
 */
export function makeGist(sdk) {
  /**
   * On-device, multi-label content topic tagging. Create one with
   * `await Gist.load(...)` and reuse it, mirroring the iOS/Swift SDK.
   *
   * ```js
   * const gist = await Gist.load();                 // downloads the model on first use, cached
   * const topics = await gist.classify("How to start a podcast with your iPhone");
   * // [{ slug: "technology", name: "Technology & Software", score: 0.93 }, ...]
   * gist.dispose();
   * ```
   */
  return class Gist {
    #model;
    constructor(model) { this.#model = model; }

    /**
     * Load the model and return a ready tagger. By default the model is
     * downloaded from the Hugging Face Hub at the pinned revision, verified, and
     * cached (the filesystem under Node, the runtime's cache in the browser).
     * Pass `directory` (Node) or `modelBaseUrl` (browser) to use files you host
     * yourself. The repo and revision are pinned to the SDK.
     */
    static async load(options = {}) {
      return new Gist(await sdk.open(options));
    }

    /**
     * The full 36-topic probability distribution for `text`
     * (`{ [slug]: probability }`). Feed these to {@link channelTopics} to roll a
     * channel up.
     *
     * `options.deviceId` (a string or a zero-arg function returning one)
     * attributes usage to a specific end-user device; it is collected per call,
     * so it is safe for concurrent multi-tenant hosts. `options.group` (an id
     * from {@link withCallGroup}) bills several calls as one.
     */
    async scores(text, options = {}) {
      const phrase = String(text ?? "");
      if (phrase.trim() === "") return {};
      return (await this.#tag(phrase, options)).scores;
    }

    /**
     * The ranked topics for `text` above the model's tuned threshold, most
     * likely first. The top topic is always returned even when nothing clears
     * the threshold; `options.topK` caps the list (default 3) and
     * `options.threshold` overrides the model's own. Empty input returns `[]`.
     */
    async classify(text, options = {}) {
      const phrase = String(text ?? "");
      if (phrase.trim() === "") return [];
      const { threshold, scores, names } = await this.#tag(phrase, options);
      const thr = options.threshold ?? threshold;
      const topK = options.topK ?? 3;
      // Ranked by score, ties broken by slug - the same order Swift produces.
      return Object.entries(scores)
        .sort((a, b) => (b[1] !== a[1] ? b[1] - a[1] : a[0] < b[0] ? -1 : 1))
        .slice(0, topK)
        .filter(([, score], i) => score >= thr || i === 0)
        .map(([slug, score]) => ({ slug, name: names[slug] ?? slug, score }));
    }

    /** One run, decoded. Both public calls need the same payload. */
    async #tag(phrase, options) {
      return decodeTagged(await this.#model.run(encodeInput(phrase), new Uint8Array(0), options));
    }

    /** Whether the model is usable with no network. */
    isDownloaded() { return this.#model.isDownloaded(); }

    /**
     * Run `body(group)` with a fresh call-group id, so every `classify({ group })`
     * inside it bills as a single usage call. The group is released when `body`
     * settles.
     */
    withCallGroup(body) { return this.#model.withCallGroup(body); }

    /**
     * Send the usage recorded so far and await the POST, so a short-lived process
     * (a CLI, a Lambda) does not exit before it lands. Usage is reported on its own
     * otherwise; such a process has no idle gap for the debounce to fire in.
     */
    flushTelemetry() { return this.#model.flushTelemetry(); }

    /** Release the model. The tagger is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}
