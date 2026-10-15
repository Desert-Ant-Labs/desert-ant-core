// Ear's public API, written once over whichever core the entry point bound
// (browser.js's WebAssembly core or node.js's native core); @desert-ant-labs/core
// turns either into the same `LoadedModel`.
import { decodeResult, encodeInput, encodeOptions, SAMPLE_RATE } from "./codec.js";

export { SAMPLE_RATE };

/**
 * Build the `Ear` class over a bound SDK (`createWasmSdk` / `createNativeSdk`).
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
     * `options.deviceId` (a string or a zero-arg function returning one) names
     * the end-user device for the call; licensing does not read it yet.
     * `options.group` has no effect.
     */
    async identify(samples, sampleRate = SAMPLE_RATE, options = {}) {
      return decodeResult(await this.#model.run(
        encodeInput(samples, sampleRate),
        encodeOptions(options),
        options));
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

    /** Release the model. The identifier is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}
