// Ear's public API, over whichever core the entry point bound: the browser's
// WebAssembly + LiteRT.js core (browser.js) or the prebuilt native core
// (node.js). Both expose the same ABI, and @desert-ant-labs/core turns either
// one into the same `LoadedModel`, so the API is written once here instead of
// once per runtime.
import { decodeResult, encodeInput, encodeOptions, SAMPLE_RATE } from "./codec.js";

export { SAMPLE_RATE };

/**
 * Build the `Ear` class over a bound SDK (`createWasmSdk` / `createNativeSdk`).
 * The entry points do nothing but call this.
 */
export function makeEar(sdk) {
  /**
   * On-device spoken language identification. Create one with
   * `await Ear.load(...)` and reuse it, mirroring the Swift and Kotlin SDKs.
   *
   * ```js
   * const ear = await Ear.load();                    // download on demand, cached
   * const d = await ear.identify(samples, 16000);
   * d.language;      // "pt"
   * d.isReliable;    // whether to route work on it
   * ear.dispose();
   * ```
   */
  return class Ear {
    #model;
    constructor(model) { this.#model = model; }

    /**
     * Load the model and return a ready identifier. By default the model is
     * downloaded from the Hugging Face Hub at the pinned revision, verified, and
     * cached (the filesystem under Node, the runtime's cache in the browser).
     * Pass `directory` (Node) or `modelBaseUrl` (browser) to use files you host
     * yourself. The repo and revision are pinned to the SDK.
     */
    static async load(options = {}) {
      return new Ear(await sdk.open(options));
    }

    /**
     * Name the language of mono `samples` at `sampleRate`. Audio at any rate is
     * resampled; 16 kHz avoids the conversion.
     *
     * Listens to `options.windows` thirty-second windows (three by default),
     * chosen by how speech-like they are rather than by position, so a jingle
     * or a long silence does not decide the answer. Shorter recordings use
     * fewer.
     *
     * Branch on `isReliable`, not on `confidence`: it is false when the top two
     * candidates are too close to separate, and false for the Nordic languages,
     * which the model confuses confidently rather than uncertainly - so their
     * probability does not reveal the problem.
     *
     * `options.deviceId` (a string or a zero-arg function returning one)
     * attributes usage to a specific end-user device; it is collected per call,
     * so it is safe for concurrent multi-tenant hosts. `options.group` (an id
     * from {@link withCallGroup}) bills several calls as one.
     */
    async identify(samples, sampleRate = SAMPLE_RATE, options = {}) {
      return decodeResult(await this.#model.run(
        encodeInput(samples, sampleRate),
        encodeOptions(options),
        options));
    }

    /** Whether the model is usable with no network. */
    isDownloaded() { return this.#model.isDownloaded(); }

    /**
     * Run `body(group)` with a fresh call-group id, so every
     * `identify({ group })` inside it bills as a single usage call. The group is
     * released when `body` settles.
     */
    withCallGroup(body) { return this.#model.withCallGroup(body); }

    /** Release the model. The identifier is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}
