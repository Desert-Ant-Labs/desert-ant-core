// Shapes' public API, written once over whichever core the entry point bound
// (browser.js's WebAssembly core or node.js's native core); @desert-ant-labs/core
// turns either into the same `LoadedModel`.
import { decodeShape, encodeInput, encodeOptions, flattenPoints } from "./codec.js";

/**
 * Build the `Shapes` class over a bound SDK (`createWasmSdk` / `createNativeSdk`).
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
     * Recognizes one hand-drawn stroke and returns the clean shape, or `null`
     * for a stroke that isn't a shape. `points` is either `[{x, y}, ...]` or a
     * flat `[x0, y0, x1, y1, ...]`.
     *
     * `options.rotation` is `"snapped"` (the default, 15° steps and snaps onto
     * the axes), `"upright"` (no rotation), or `"free"` (as drawn).
     * `options.kinds` lists the kinds Shapes recognizes, all 13 by default.
     * `options.minimumConfidence` (default `0`) is the lowest classifier
     * confidence Shapes accepts, on top of each kind's calibrated threshold. `options.deviceId` (a string or a
     * zero-arg function returning one) names the end-user device for the call;
     * licensing does not read it yet. `options.group` has no effect.
     */
    async recognize(points, options = {}) {
      const flat = flattenPoints(points);
      if (flat.length < 4) return null;   // fewer than two points is degenerate
      const payload = encodeOptions(options);
      return decodeShape(
        await this.#model.run(encodeInput(flat), payload, options));
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

    /** Release the model. The recognizer is unusable afterwards. */
    dispose() { this.#model.dispose(); }
  };
}

/**
 * An arrow's heads, each an open polyline `[barb, tip, barb]` with barbs
 * `length` long in canvas units. For any other shape, the array is empty. The
 * geometry matches Swift's `Shape.arrowheads(length:)`.
 */
export function arrowheads(shape, length) {
  if (shape?.kind !== "arrow") return [];
  const { from: a, control1: c1, control2: c2, to: b } = shape;
  const at = (t) => {
    const u = 1 - t;
    const k = [u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t];
    return {
      x: k[0] * a.x + k[1] * c1.x + k[2] * c2.x + k[3] * b.x,
      y: k[0] * a.y + k[1] * c1.y + k[2] * c2.y + k[3] * b.y,
    };
  };
  const head = (tip, from) => {
    const dx = tip.x - from.x, dy = tip.y - from.y, n = Math.hypot(dx, dy) || 1;
    const bx = -dx / n, by = -dy / n, s = 0.45;
    const barb = (ang) => ({
      x: tip.x + length * (Math.cos(ang) * bx - Math.sin(ang) * by),
      y: tip.y + length * (Math.sin(ang) * bx + Math.cos(ang) * by),
    });
    return [barb(s), { ...tip }, barb(-s)];
  };
  const heads = [];
  if (shape.startHead) heads.push(head(a, at(2 / 32)));
  if (shape.endHead) heads.push(head(b, at(30 / 32)));
  return heads;
}
