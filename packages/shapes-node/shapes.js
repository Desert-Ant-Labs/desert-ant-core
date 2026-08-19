// Shapes' public API, over whichever core the entry point bound: the browser's
// WebAssembly + LiteRT.js core (browser.js) or the prebuilt native core
// (node.js). Both expose the same ABI, and @desert-ant-labs/core turns either
// one into the same `LoadedModel`, so the API is written once here instead of
// once per runtime.
import { decodeShape, encodeInput, encodeOptions, flattenPoints } from "./codec.js";

/**
 * Build the `Shapes` class over a bound SDK (`createWasmSdk` / `createNativeSdk`).
 * The entry points do nothing but call this.
 */
export function makeShapes(sdk) {
  /**
   * On-device single-stroke shape recognition. Create one with
   * `await Shapes.load(...)` and reuse it, mirroring the Swift SDK.
   *
   * ```js
   * const shapes = await Shapes.load();          // downloads the model on first use, cached
   * const shape = await shapes.recognize(points); // { kind: "ellipse", ... } | null
   * shapes.dispose();
   * ```
   */
  return class Shapes {
    #model;
    constructor(model) { this.#model = model; }

    /**
     * Load the model and return a ready recognizer. By default the model is
     * downloaded from the Hugging Face Hub at the pinned revision, verified, and
     * cached (the filesystem under Node, the runtime's cache in the browser).
     * Pass `directory` (Node) or `modelBaseUrl` (browser) to use files you host
     * yourself. The repo and revision are pinned to the SDK.
     */
    static async load(options = {}) {
      return new Shapes(await sdk.open(options));
    }

    /**
     * Recognize one hand-drawn stroke and return the fitted shape, or `null`
     * when the stroke is rejected or too short to mean anything. `points` is
     * either `[{x, y}, ...]` or a flat `[x0, y0, x1, y1, ...]`.
     *
     * `options.minimumConfidence` (default `0`) raises the classifier threshold
     * on top of each class's calibrated gate. `options.deviceId` (a string or a
     * zero-arg function returning one) attributes usage to a specific end-user
     * device; it is collected per call, so it is safe for concurrent
     * multi-tenant hosts. `options.group` (an id from {@link withCallGroup})
     * bills several calls as one.
     */
    async recognize(points, options = {}) {
      const flat = flattenPoints(points);
      if (flat.length < 4) return null;   // fewer than two points is degenerate
      const payload = encodeOptions({
        minimumConfidence: Number(options.minimumConfidence ?? 0),
      });
      return decodeShape(
        await this.#model.run(encodeInput(flat), payload, options));
    }

    /** Whether the model is usable with no network. */
    isDownloaded() { return this.#model.isDownloaded(); }

    /**
     * Run `body(group)` with a fresh call-group id, so every
     * `recognize({ group })` inside it bills as a single usage call. The group
     * is released when `body` settles.
     */
    withCallGroup(body) { return this.#model.withCallGroup(body); }

    /** Release the model. The recognizer is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}
