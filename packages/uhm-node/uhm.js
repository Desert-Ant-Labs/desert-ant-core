// Uhm's public API, written once over whichever core the entry point bound
// (browser.js's WebAssembly core or node.js's native core); @desert-ant-labs/core
// turns either into the same `LoadedModel`.
import { BIAS, SAMPLE_RATE, decodeResult, encodeInput, encodeOptions } from "./codec.js";

export { BIAS, SAMPLE_RATE };

/**
 * Build the `Uhm` class over a bound SDK (`createWasmSdk` / `createNativeSdk`).
 */
export function makeUhm(sdk) {
  /**
   * On-device filler-word detection. Create one with `await Uhm.load(...)` and
   * reuse it, mirroring the Swift and Kotlin SDKs.
   *
   * ```js
   * const uhm = await Uhm.load();                      // download on demand, cached
   * const r = await uhm.detect(samples, 16000);
   * r.fillers;          // [{ start, end, confidence, type }]
   * r.audioDuration;
   * uhm.dispose();
   * ```
   */
  return class Uhm {
    #model;
    constructor(model) { this.#model = model; }

    /**
     * Load the model and return a ready detector. By default the model is
     * downloaded from the Hugging Face Hub at the pinned revision, verified, and
     * cached (the filesystem under Node, the runtime's cache in the browser).
     * Pass `directory` (Node) or `modelBaseUrl` (browser) to use files you host
     * yourself. The repo and revision are pinned to the SDK.
     */
    static async load(options = {}) {
      return new Uhm(await sdk.open(options));
    }

    /**
     * Find filler spans in mono `samples` at `sampleRate`. Audio at any rate is
     * resampled; 16kHz avoids the conversion.
     *
     * `options.bias` is the threshold preset: `"precision"` (0.75) for
     * automatic cuts, `"balanced"` (0.65, the default), `"recall"` (0.5) when
     * you would rather review than miss one. `minConfidence` overrides it.
     * `minDurationSec` drops shorter spans (default 0.12).
     *
     * Pass `options.words` (`{ start, end, text }` from your transcript) and
     * the result carries `words`: the same ranges trimmed, split, or dropped so
     * a cut at a filler never clips a real word. `options.reconcile` tunes it
     * (`minOverlapFraction`, `splitContainedWords`).
     *
     * `type` is null outside Apple: the per-filler type labeler is SoundAnalysis.
     *
     * `options.deviceId` (a string or a zero-arg function returning one) names
     * the end-user device for the call; licensing does not read it yet.
     * `options.group` has no effect.
     */
    async detect(samples, sampleRate = SAMPLE_RATE, options = {}) {
      return decodeResult(await this.#model.run(
        encodeInput(samples, sampleRate, options.words),
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

    /** Release the model. The detector is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}
