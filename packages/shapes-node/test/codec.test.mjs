// The payloads shapes-node writes and reads, without the model: `isFinished`
// is the last options field, the lasso is gone, and a plus or a cross comes
// back with one path per stroke (Sources/Shapes/Binding.swift).
import assert from "node:assert/strict";
import { test } from "node:test";

import { FfiReader, FfiWriter } from "@desert-ant-labs/core";

import { KINDS, decodeShape, encodeOptions } from "../codec.js";

const readOptions = (bytes) => {
  const r = new FfiReader(bytes);
  return [r.f64(), r.u32(), r.u32(), r.u32()];
};

test("isFinished is the last options field, true by default", () => {
  assert.deepEqual(readOptions(encodeOptions()), [0, 0, 0, 1]);
  assert.deepEqual(readOptions(encodeOptions({ isFinished: false })), [0, 0, 0, 0]);
});

test("the lasso is not a kind", () => {
  assert.equal(KINDS.includes("lasso"), false);
  assert.equal(KINDS[18], "zigzag", "the numbers after it keep their meaning");
  assert.throws(() => encodeOptions({ kinds: ["lasso"] }), TypeError);
});

test("a plus draws as its two strokes, a line as its outline", () => {
  const points = (w, ps) => { w.u32(ps.length); for (const [x, y] of ps) w.f64(x).f64(y); };
  const plus = new FfiWriter().u32(1).u32(KINDS.indexOf("plus"));
  for (const [x, y] of [[0, 50], [100, 50], [50, 0], [50, 100]]) plus.f64(x).f64(y);
  points(plus, [[0, 50], [100, 50], [50, 0], [50, 100]]);
  const p = decodeShape(new FfiReader(plus.done()));
  assert.deepEqual(p.paths, [[{ x: 0, y: 50 }, { x: 100, y: 50 }], [{ x: 50, y: 0 }, { x: 50, y: 100 }]]);

  const line = new FfiWriter().u32(1).u32(KINDS.indexOf("line"));
  line.f64(0).f64(0).f64(10).f64(10);
  points(line, [[0, 0], [10, 10]]);
  const l = decodeShape(new FfiReader(line.done()));
  assert.deepEqual(l.paths, [l.outline]);
});
