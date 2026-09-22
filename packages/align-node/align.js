// Align's public API, over whichever core the entry point bound. Today that is only the native one.
import { LANGUAGES, decodeResult, encodeInput, encodeOptions, languageKey } from "./codec.js";

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

    /** The same words with `start` and `end` replaced and `refined` added; unsupported languages pass through. */
    async refine(samples, sampleRate, words, options) {
      if (!options || typeof options.language !== "string") throw new Error("align: options.language is required");
      const reader = await this.#model.run(encodeInput(samples, sampleRate, words),
                                           encodeOptions({ language: options.language }), options);
      return decodeResult(reader, words);
    }

    /** Whether the model is usable with no network. */
    isDownloaded() { return this.#model.isDownloaded(); }

    /** Run `body(group)` with a fresh call-group id, so every `refine({ group })` inside it bills as one. */
    withCallGroup(body) { return this.#model.withCallGroup(body); }

    /** Release the model. The refiner is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}
