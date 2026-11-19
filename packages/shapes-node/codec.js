// Shapes' FFI payload schemas: the drawing a run takes, the options beside it,
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
 *  (`wireKinds`). Index 0 is unused because 0 is the "no shape" flag, and 17
 *  (the lasso) is unused. A number never changes meaning. */
export const KINDS = [null, "line", "rectangle", "triangle", "ellipse", "star",
  "curve", "arrow", "diamond", "pentagon", "hexagon", "heart", "cloud", "scribble",
  "check", "cross", "bracket", null, "zigzag", "plus"];

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

/**
 * Normalize what `recognize` accepts into strokes of flat points and optional
 * times: one stroke as `[{x, y}, ...]` or `[x0, y0, ...]`, or a drawing as
 * `[{points, times?}, ...]`, where `points` takes either spelling and `times`
 * holds a time in milliseconds for each point.
 */
export function normalizeStrokes(input) {
  const list = Array.from(input ?? []);
  if (list.length === 0) return [];
  const first = list[0];
  if (first !== null && typeof first === "object" && "points" in first) {
    return list.map((s) => ({
      flat: flattenPoints(s?.points),
      times: s?.times == null ? null : Array.from(s.times, Number),
    }));
  }
  return [{ flat: flattenPoints(list), times: null }];
}

/** Input payload: `u32 strokes`, then for each stroke `u32 count`, `u32 timed`
 *  (1 when every point has a time), and the points, each `f64 x`, `f64 y` and,
 *  when timed, `f64 t`. Mirrors Shapes' `run(input:options:)` in
 *  Sources/Shapes/Binding.swift. */
export function encodeInput(strokes) {
  const w = new FfiWriter().u32(strokes.length);
  for (const { flat, times } of strokes) {
    const count = Math.floor(flat.length / 2);
    const timed = times != null && times.length === count;
    w.u32(count).u32(timed ? 1 : 0);
    for (let i = 0; i < count; i++) {
      w.f64(flat[2 * i]).f64(flat[2 * i + 1]);
      if (timed) w.f64(times[i]);
    }
  }
  return w.done();
}

/** Options payload: `f64 minimumConfidence`, `u32 rotation`, `u32 kinds`, a
 *  bit mask with bit n for wire kind n (0 means every kind), and `u32 finished`
 *  (1, the default, or 0 for a preview while the pen still moves). */
export function encodeOptions({ minimumConfidence = 0, rotation = "snapped", kinds, isFinished = true } = {}) {
  const r = ROTATIONS.indexOf(rotation);
  if (r < 0) throw new TypeError(`rotation must be one of ${ROTATIONS.join(", ")}, got ${JSON.stringify(rotation)}`);
  let mask = 0;
  for (const kind of kinds ?? []) {
    const n = kind == null ? -1 : KINDS.indexOf(kind);
    if (n <= 0) throw new TypeError(`unknown shape kind ${JSON.stringify(kind)}`);
    mask |= 1 << n;
  }
  return new FfiWriter().f64(Number(minimumConfidence)).u32(r).u32(mask >>> 0).u32(isFinished ? 1 : 0).done();
}

/**
 * Result payload: `u32 present`, which is 0 for a drawing that isn't a shape,
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
    case "check":
      shape = { kind, start: point(), corner: point(), end: point() };
      break;
    case "cross":
    case "plus":
      shape = { kind, firstFrom: point(), firstTo: point(), secondFrom: point(), secondTo: point() };
      break;
    case "bracket":
      shape = { kind, points: points() };
      break;
    case "zigzag":
      shape = { kind, from: point(), to: point(), amplitude: r.f64(), teeth: r.f64() };
      break;
    default:
      // A kind this SDK does not know is a core newer than the package. Report
      // it as "no shape" rather than half-decoding a payload we cannot read.
      return null;
  }
  const outline = points();
  if (kind !== "cloud") shape.outline = outline;
  // the polylines to draw: a plus's or a cross's two strokes, the outline for any other kind
  shape.paths = kind === "cross" || kind === "plus"
    ? [[shape.firstFrom, shape.firstTo], [shape.secondFrom, shape.secondTo]]
    : [shape.outline];
  return shape;
}
