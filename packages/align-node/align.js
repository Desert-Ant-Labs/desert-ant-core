// Align's public API, over whichever core the entry point bound. Today that is only the native one.
import { LANGUAGES, decodeResult, encodeInput, encodeOptions, languageKey, validateInput } from "./codec.js";

// sdkVersion is passed in: importing package.json here would inline it into every browser bundle.
/** Build the `Align` class over a bound SDK. The entry points do nothing but call this. */
export function makeAlign(sdk, sdkVersion) {
  /** On-device word-timestamp refinement. Create one with `await Align.load()` and reuse it. */
  return class Align {
    #model;
    constructor(model) { this.#model = model; }

    /** The nine language codes the model was trained on. */
    static get languages() { return LANGUAGES; }
    /** True when `refine` corrects times for this language; false means passthrough. */
    static isSupported(language) { return LANGUAGES.includes(languageKey(language)); }
    /** This package's version, the same number as the core it pins. */
    static get sdkVersion() { return sdkVersion; }
    get languages() { return LANGUAGES; }
    isSupported(language) { return Align.isSupported(language); }
    get sdkVersion() { return sdkVersion; }

    /** Download at the pinned revision and cache, or adopt a `directory` you host yourself. */
    static async load(options = {}) { return new Align(await sdk.open(options)); }

    /**
     * The same words with `start` and `end` replaced and `refined` added; unsupported languages pass through.
     * Every `start` and `end` must be a finite number from -1 to 10,000,000 seconds, `sampleRate` finite and
     * positive, and `samples` non-empty, or this rejects with a `RangeError`. A word more than about 1.2 s past
     * the end of the audio keeps its times, `refined: false`.
     */
    async refine(samples, sampleRate, words, options) {
      if (!options || typeof options.language !== "string") throw new Error("align: options.language is required");
      validateInput(samples, sampleRate, words);
      const reader = await this.#model.run(encodeInput(samples, sampleRate, words),
                                           encodeOptions({ language: options.language }), options);
      return decodeResult(reader, words);
    }

    /** Whether the model is usable with no network. */
    isDownloaded() { return this.#model.isDownloaded(); }

    /** Run `body(group)` with a fresh call-group id, so every `refine({ group })` inside it bills as one. */
    withCallGroup(body) { return this.#model.withCallGroup(body); }

    /**
     * Send the usage this refiner has recorded and await the POST, so a worker
     * that stops right after a refinement does not exit before it lands. Usage is
     * reported on its own; this is for a short-lived process, which has no idle
     * gap for the debounce to fire in.
     */
    flushTelemetry() { return this.#model.flushTelemetry(); }

    /** Release the model. The refiner is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}
