import { test } from "node:test";
import assert from "node:assert/strict";
import { Faceprint, Level, matches } from "../index.js";

test("faceprints compare by cosine and round-trip through JSON and bytes", () => {
  const a = new Faceprint([3, 4, ...new Array(126).fill(0)]);
  const b = new Faceprint([4, 3, ...new Array(126).fill(0)]);
  assert.ok(Math.abs(a.similarity(b) - 0.96) < 1e-6);
  assert.ok(a.isSamePerson(b, "strict") && Level.recommended < Level.strict);
  assert.ok(!a.isSamePerson(new Faceprint(b.values, "face-0")), "faceprints of different models never match");
  const short = new Faceprint(a.values.slice(0, 64));
  assert.ok(a.similarity(short) === 0 && short.similarity(a) === 0, "faceprints of different lengths never compare");
  assert.ok(!a.isSamePerson(short) && !short.isSamePerson(a) && !a.isComparable(short));
  assert.deepEqual(matches(a, [short, b]).map((m) => m.index), [1]);
  assert.deepEqual(matches(short, [a]), []);
  assert.deepEqual(Faceprint.fromJSON(JSON.parse(JSON.stringify(a))).values, a.values);
  assert.deepEqual(Faceprint.fromData(a.data, a.model).values, a.values);
  assert.deepEqual(matches(a, [b, new Faceprint([0, 0, 1])]).map((m) => m.index), [0]);
});
