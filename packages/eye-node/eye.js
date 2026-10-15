// Eye's public API, written once over whichever core the entry point bound
// (browser.js's WebAssembly core or node.js's native core).
import { best, duplicates, similar } from "./analysis.js";
import { decodeAnalysis, encodeInput, encodeOptions, toPixels } from "./codec.js";

/**
 * Build the `Eye` class over a bound SDK (`createWasmSdk` / `createNativeSdk`).
 */
export function makeEye(sdk) {
  /**
   * On-device photo understanding. Create one with `await Eye.load()` and reuse
   * it, mirroring the Swift SDK.
   *
   * ```js
   * const eye = await Eye.load();
   * const photo = await eye.analyze(imageData);
   * if (photo.has(Tag.dog) && !photo.has(Tag.blurry)) keep(photo);
   * eye.dispose();
   * ```
   */
  return class Eye {
    #model;
    constructor(model) { this.#model = model; }

    /**
     * Load the model and return a ready eye. By default the model is downloaded
     * from the Hugging Face Hub at the pinned revision, verified, and cached.
     * Pass `directory` (Node) or `modelBaseUrl` (browser) to use files you host
     * yourself.
     */
    static async load(options = {}) {
      return new Eye(await sdk.open(options));
    }

    /**
     * Analyze an image. `image` is `{ data, width, height }` with RGB or RGBA
     * bytes (an `ImageData` works as is), or in the browser anything
     * `createImageBitmap` accepts.
     *
     * `options.parts` (default all of `"photo"`, `"layout"`, `"faces"`,
     * `"sharpness"`) chooses what to compute; tags and fields of a part not
     * asked for are absent.
     * `options.maxFaces` (default 20) caps the faces analyzed. `options.deviceId`
     * and `options.group` attribute and bill usage as in every other model.
     */
    async analyze(image, options = {}) {
      const pixels = await toPixels(image);
      return decodeAnalysis(await this.#model.run(encodeInput(pixels), encodeOptions(options), options));
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

    /** Release the model. The eye is unusable afterwards. */
    dispose() { this.#model.dispose(); }

    /** Groups of near-duplicates (indices), best first; `options.dates` are capture times in seconds. */
    static duplicates(analyses, options) { return duplicates(analyses, options); }

    /** The index of the photo to keep from a set. */
    static best(analyses) { return best(analyses); }

    /** Photos ranked by similarity to `photo`: [{ index, similarity }]. */
    static similar(photo, analyses, options) { return similar(photo, analyses, options); }
  };
}
