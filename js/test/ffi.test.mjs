import { test } from "node:test";
import assert from "node:assert/strict";
import { FfiReader } from "../src/ffi.js";

// Build a big-endian buffer the way the Swift FFIWriter / Kotlin FfiReader do.
function buildPayload() {
  const parts = [];
  const u32 = (v) => { const b = Buffer.alloc(4); b.writeUInt32BE(v >>> 0); parts.push(b); };
  const i32 = (v) => { const b = Buffer.alloc(4); b.writeInt32BE(v); parts.push(b); };
  const f64 = (v) => { const b = Buffer.alloc(8); b.writeDoubleBE(v); parts.push(b); };
  const str = (s) => { const u = Buffer.from(s, "utf8"); u32(u.length); parts.push(u); };
  return { u32, i32, f64, str, done: () => new Uint8Array(Buffer.concat(parts)) };
}

test("FfiReader reads u32/i32/f64/str big-endian in order", () => {
  const b = buildPayload();
  b.u32(5);
  b.f64(3.5);
  b.i32(-7);
  b.str("héllo");        // multi-byte UTF-8
  b.u32(0xdeadbeef);
  const r = new FfiReader(b.done());
  assert.equal(r.u32(), 5);
  assert.equal(r.f64(), 3.5);
  assert.equal(r.i32(), -7);
  assert.equal(r.str(), "héllo");
  assert.equal(r.u32(), 0xdeadbeef);
  assert.equal(r.remaining, 0);
});

test("FfiReader mirrors a shapes-style line payload", () => {
  // present(1), kind line(1), from(x,y), to(x,y)
  const b = buildPayload();
  b.u32(1);
  b.u32(1);
  b.f64(1); b.f64(2);
  b.f64(3); b.f64(4);
  const r = new FfiReader(b.done());
  assert.equal(r.u32(), 1);          // present
  assert.equal(r.u32(), 1);          // line
  assert.deepEqual([r.f64(), r.f64()], [1, 2]);
  assert.deepEqual([r.f64(), r.f64()], [3, 4]);
});

test("FfiReader.bytes returns a view and advances", () => {
  const src = new Uint8Array([10, 20, 30, 40, 50]);
  const r = new FfiReader(src);
  assert.deepEqual(Array.from(r.bytes(3)), [10, 20, 30]);
  assert.equal(r.offset, 3);
  assert.deepEqual(Array.from(r.bytes(2)), [40, 50]);
});
