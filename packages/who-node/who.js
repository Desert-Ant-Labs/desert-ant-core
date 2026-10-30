// Who's public API, written once over whichever core the entry point bound
// (browser.js's WebAssembly core or node.js's native core).
import { decodeDiarization, encodeInput, encodeOptions, toAudio } from "./codec.js";

/**
 * Build the `Who` class over a bound SDK (`createWasmSdk` / `createNativeSdk`)
 * and the platform's audio decoder (file bytes to mono samples at a rate).
 */
export function makeWho(sdk, decodeAudio) {
  /**
   * On-device speaker diarization. Create one with `await Who.load()` and reuse
   * it, mirroring the Swift SDK.
   *
   * ```js
   * const who = await Who.load();
   * const result = await who.diarize(file);
   * for (const turn of result.turns) console.log(turn.speaker, turn.start, turn.end);
   * who.dispose();
   * ```
   */
  return class Who {
    #model;
    constructor(model) { this.#model = model; }

    /**
     * Load the model and return a ready instance. By default the model is
     * downloaded from the Hugging Face Hub at the pinned revision, verified,
     * and cached. Pass `directory` (Node) or `modelBaseUrl` (browser) to use
     * files you host yourself.
     */
    static async load(options = {}) {
      return new Who(await sdk.open(options));
    }

    /**
     * Who spoke when. `input` is the bytes of an audio file (`File`, `Blob`,
     * `ArrayBuffer`, `Uint8Array`), mono `Float32Array` samples at 16 kHz, or
     * `{ samples, sampleRate }` at any rate; `options.sampleRate` names the
     * rate of bare samples. `options.deviceId` attributes usage as in every
     * other model.
     */
    async diarize(input, options = {}) {
      const audio = await toAudio(input, options.sampleRate, decodeAudio);
      return decodeDiarization(await this.#model.run(encodeInput(audio), encodeOptions(), options));
    }

    /**
     * Send the usage recorded so far and await the POST, so a short-lived process
     * (a CLI, a Lambda) does not exit before it lands.
     */
    flushTelemetry() { return this.#model.flushTelemetry(); }

    /** Whether the model is usable with no network. */
    isDownloaded() { return this.#model.isDownloaded(); }

    /** Run `body(group)` with a fresh call-group id, so every call inside bills once. */
    withCallGroup(body) { return this.#model.withCallGroup(body); }

    /** Release the model. The instance is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}
