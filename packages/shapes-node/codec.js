// Shapes' FFI payload schemas: the stroke a run takes, the options beside it,
// and the shape it returns.
//
// Both cores (the native `dal_run` and the WebAssembly `run`) speak the same
// payloads, so they live here once.
// Mirrors the reader/writer in Sources/Shapes/Binding.swift.
import { FfiWriter } from "@desert-ant-labs/core";

/** The catalog id: how both cores are asked for Shapes, and the key its
 *  WebAssembly exports are registered under. */
export const MODEL_ID = "shapes";

export const PACKAGE_NAME = "@desert-ant-labs/shapes";

/** Shape kinds by wire number, as Sources/Shapes/Binding.swift writes them
 *  (`wireKinds`). Index 0 is unused because 0 is the "no shape" flag. A number
 *  never changes meaning. */
export const KINDS = [null, "line", "rectangle", "triangle", "ellipse", "star",
  "curve", "arrow", "diamond", "pentagon", "hexagon", "heart", "cloud", "scribble"];

/** Rotation modes by wire number. */
const ROTATIONS = ["snapped", "upright", "free"];

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

/** Options payload: `f64 minimumConfidence`, `u32 rotation`, and `u32 kinds`,
 *  a bit mask with bit n for wire kind n (0 means every kind). */
export function encodeOptions({ minimumConfidence = 0, rotation = "snapped", kinds } = {}) {
  const r = ROTATIONS.indexOf(rotation);
  if (r < 0) throw new TypeError(`rotation must be one of ${ROTATIONS.join(", ")}, got ${JSON.stringify(rotation)}`);
  let mask = 0;
  for (const kind of kinds ?? []) {
    const n = KINDS.indexOf(kind);
    if (n <= 0) throw new TypeError(`unknown shape kind ${JSON.stringify(kind)}`);
    mask |= 1 << n;
  }
  return new FfiWriter().f64(Number(minimumConfidence)).u32(r).u32(mask >>> 0).done();
}

/**
 * Result payload: `u32 present`, which is 0 for a stroke that isn't a shape,
 * with nothing after it. Otherwise `u32 kind` follows, then that kind's
 * fields, then the outline.
 * `r` is an FfiReader already positioned at the payload.
 */
export function decodeShape(r) {
  if (r.u32() === 0) return null;
  const kind = KINDS[r.u32()];
  const point = () => ({ x: r.f64(), y: r.f64() });
  const points = () => Array.from({ length: r.u32() }, point);
  let shape;
  switch (kind) {
    case "line":
      shape = { kind, from: point(), to: point() };
      break;
    case "curve":
      shape = { kind, from: point(), control1: point(), control2: point(), to: point() };
      break;
    case "arrow":
      shape = {
        kind, from: point(), control1: point(), control2: point(), to: point(),
        startHead: r.u32() === 1, endHead: r.u32() === 1,
      };
      break;
    case "rectangle":
      shape = { kind, corners: points() };
      break;
    case "ellipse":
      shape = { kind, center: point(), semiMajor: r.f64(), semiMinor: r.f64(), rotation: r.f64() };
      break;
    case "triangle":
    case "diamond":
    case "pentagon":
    case "hexagon":
      shape = { kind, vertices: points() };
      break;
    case "star":
      shape = {
        kind, center: point(), outerRadius: r.f64(), innerRadius: r.f64(),
        rotation: r.f64(), pointCount: r.u32(),
      };
      break;
    case "heart":
      shape = { kind, center: point(), width: r.f64(), height: r.f64() };
      break;
    case "cloud":
      shape = { kind, outline: points() };
      break;
    case "scribble":
      shape = { kind, hull: points() };
      break;
    default:
      // A kind this SDK does not know is a core newer than the package. Report
      // it as "no shape" rather than half-decoding a payload we cannot read.
      return null;
  }
  const outline = points();
  if (kind !== "cloud") shape.outline = outline;
  return shape;
}
