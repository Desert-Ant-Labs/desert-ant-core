// Shapes' FFI payload schemas: the stroke a run takes, the options beside it,
// and the shape it returns.
//
// These are the only model-specific part of talking to the core, and both cores
// speak the same payloads - the native `dal_run` (node.js) and the WebAssembly
// `run` (browser.js) - so they live here once instead of in each entry point.
// Mirrors the reader/writer in Sources/Shapes/Binding.swift.
import { FfiWriter } from "@desert-ant-labs/core";

/** The catalog id: how both cores are asked for Shapes, and the key its
 *  WebAssembly exports are registered under. */
export const MODEL_ID = "shapes";

export const PACKAGE_NAME = "@desert-ant-labs/shapes";

/** Shape kinds, in the wire order Sources/Shapes/Binding.swift writes. Index 0
 *  is unused: a `kind` is 1-based, because 0 is the "no shape" flag. */
const KINDS = [null, "line", "rectangle", "triangle", "ellipse", "star"];

/**
 * Normalize the two accepted stroke spellings into a flat [x0, y0, x1, y1, ...]
 * sequence: an array of `{x, y}` points, or an already-flat array of numbers.
 * Both are common in canvas code, and accepting either here keeps the check out
 * of the API surface.
 */
export function flattenPoints(points) {
  const list = Array.from(points ?? []);
  if (list.length === 0) return [];
  if (typeof list[0] === "number") return list.map(Number);
  const flat = [];
  for (const p of list) {
    flat.push(Number(p?.x ?? 0), Number(p?.y ?? 0));
  }
  return flat;
}

/** Input payload: `u32 count`, then that many `f64 x`, `f64 y` pairs. Mirrors
 *  Shapes' `run(input:options:)` in Sources/Shapes/Binding.swift. */
export function encodeInput(flat) {
  const w = new FfiWriter().u32(Math.floor(flat.length / 2));
  for (const value of flat) w.f64(value);
  return w.done();
}

/** Options payload: `f64 minimumConfidence`. */
export function encodeOptions({ minimumConfidence }) {
  return new FfiWriter().f64(minimumConfidence).done();
}

/**
 * Result payload: `u32 present` (0 when the stroke was rejected or degenerate,
 * and nothing follows), else `u32 kind` and that kind's fields. `r` is an
 * FfiReader already positioned at the payload.
 */
export function decodeShape(r) {
  if (r.u32() === 0) return null;
  const kind = KINDS[r.u32()];
  const point = () => ({ x: r.f64(), y: r.f64() });
  const points = () => Array.from({ length: r.u32() }, point);
  switch (kind) {
    case "line":
      return { kind, from: point(), to: point() };
    case "rectangle":
      return { kind, corners: points() };
    case "triangle":
      return { kind, vertices: points() };
    case "ellipse":
      return { kind, center: point(), semiMajor: r.f64(), semiMinor: r.f64(), rotation: r.f64() };
    case "star":
      return {
        kind,
        center: point(),
        outerRadius: r.f64(),
        innerRadius: r.f64(),
        rotation: r.f64(),
        pointCount: r.u32(),
      };
    default:
      // A kind this SDK does not know is a core newer than the package. Report
      // it as "no shape" rather than half-decoding a payload we cannot read.
      return null;
  }
}
