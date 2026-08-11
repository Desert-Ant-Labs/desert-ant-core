// Clear's public API, over whichever core the entry point bound: the browser's
// WebAssembly + LiteRT.js core (browser.js) or the prebuilt native core
// (node.js). Both expose the same ABI, and @desert-ant-labs/core turns either
// one into the same `LoadedModel`, so the API is written once here instead of
// once per runtime.
import { decodeResult, encodeInput, encodeOptions, LOUDNESS_PRESETS } from "./codec.js";

export { LOUDNESS_PRESETS };

/**
 * Build the `Clear` class over a bound SDK (`createWasmSdk` /
 * `createNativeSdk`). The entry points do nothing but call this.
 */
export function makeClear(sdk) {
  /**
   * On-device speech enhancement. Create one with `await Clear.load(...)` and
   * reuse it, mirroring the Swift and Kotlin SDKs.
   *
   * ```js
   * const clear = await Clear.load();                 // download on demand, cached
   * const r = await clear.enhance(samples, 48000);
   * r.samples; r.measuredLUFS; r.measuredTruePeakDBFS;
   * clear.dispose();
   * ```
   */
  return class Clear {
    #model;
    constructor(model) { this.#model = model; }

    /**
     * Load the model and return a ready enhancer. By default the model is
     * downloaded from the Hugging Face Hub at the pinned revision, verified, and
     * cached (the filesystem under Node, the runtime's cache in the browser).
     * Pass `directory` (Node) or `modelBaseUrl` (browser) to use files you host
     * yourself. The repo and revision are pinned to the SDK.
     */
    static async load(options = {}) {
      return new Clear(await sdk.open(options));
    }

    /**
     * Enhance mono `samples` at `sampleRate`: denoise, dereverb, then master to
     * a delivery target. Returns 48 kHz mono, whatever the input rate.
     *
     * `options.targetLUFS` takes a number or a key of {@link LOUDNESS_PRESETS};
     * pass null to skip mastering and get the model's own level back.
     *
     * `options.deviceId` (a string or a zero-arg function returning one)
     * attributes usage to a specific end-user device; it is collected per call,
     * so it is safe for concurrent multi-tenant hosts. `options.group` (an id
     * from {@link withCallGroup}) bills several calls as one.
     */
    async enhance(samples, sampleRate = 48_000, options = {}) {
      const target = options.targetLUFS === undefined
        ? LOUDNESS_PRESETS.applePodcasts
        : options.targetLUFS;
      const payload = encodeOptions({
        strength: options.strength ?? 1,
        targetLUFS: typeof target === "string" ? LOUDNESS_PRESETS[target] : target,
        peakCeilingDBFS: options.peakCeilingDBFS ?? -1.5,
        maxGainDB: options.maxGainDB ?? 9,
      });
      return decodeResult(
        await this.#model.run(encodeInput(samples, sampleRate), payload, options));
    }

    /** Whether the model is usable with no network. */
    isDownloaded() { return this.#model.isDownloaded(); }

    /**
     * Run `body(group)` with a fresh call-group id, so every
     * `enhance({ group })` inside it bills as a single usage call. The group is
     * released when `body` settles.
     */
    withCallGroup(body) { return this.#model.withCallGroup(body); }

    /** Release the model. The enhancer is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}
