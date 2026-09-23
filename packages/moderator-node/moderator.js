// Moderator's public API, written once over whichever core the entry point
// bound (browser.js's WebAssembly core or node.js's native core).
import { decodeModeration, encodeInput, encodeOptions, toPixels } from "./codec.js";

/**
 * Build the `Moderator` class over a bound SDK (`createWasmSdk` / `createNativeSdk`).
 */
export function makeModerator(sdk) {
  /**
   * On-device NSFW image detection. Create one with `await Moderator.load()`
   * and reuse it, mirroring the Swift SDK.
   *
   * ```js
   * const moderator = await Moderator.load();
   * const { score, isNSFW, regions } = await moderator.analyze(imageData);
   * moderator.dispose();
   * ```
   */
  return class Moderator {
    #model;
    constructor(model) { this.#model = model; }

    /**
     * Load the model and return a ready moderator. By default the model is
     * downloaded from the Hugging Face Hub at the pinned revision, verified, and
     * cached. Pass `directory` (Node) or `modelBaseUrl` (browser) to use files
     * you host yourself.
     */
    static async load(options = {}) {
      return new Moderator(await sdk.open(options));
    }

    /**
     * Score an image. `image` is `{ data, width, height }` with RGB or RGBA
     * bytes (an `ImageData` works as is), or in the browser anything
     * `createImageBitmap` accepts.
     *
     * `options.threshold` (default `0.5`), `options.policy` (`"standard"` or
     * `"allowTopless"`), `options.quality` (`"fast"`, `"balanced"`, or
     * `"accurate"`, the default). `options.deviceId` and `options.group` attribute
     * and bill usage as in every other model.
     */
    async analyze(image, options = {}) {
      const pixels = await toPixels(image);
      return decodeModeration(
        await this.#model.run(encodeInput(pixels), encodeOptions(options), options));
    }

    /**
     * Send the usage recorded so far and await the POST, so a short-lived process
     * (a CLI, a Lambda) does not exit before it lands. Usage is reported on its own
     * otherwise; such a process has no idle gap for the debounce to fire in.
     */
    flushTelemetry() { return this.#model.flushTelemetry(); }

    /** Whether the model is usable with no network. */
    isDownloaded() { return this.#model.isDownloaded(); }

    /** Run `body(group)` with a fresh call-group id, so every call inside bills once. */
    withCallGroup(body) { return this.#model.withCallGroup(body); }

    /** Release the model. The moderator is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}
