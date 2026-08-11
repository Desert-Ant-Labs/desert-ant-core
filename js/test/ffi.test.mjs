import { test } from "node:test";
import assert from "node:assert/strict";
import { FfiReader, FfiWriter } from "../src/ffi.js";

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

test("FfiReader reads an f32Array the way Swift writes one", () => {
  // Built independently of FfiWriter, so this pins the wire format rather than
  // just proving the writer and reader agree with each other.
  const parts = [];
  const count = Buffer.alloc(4);
  count.writeUInt32BE(4);
  parts.push(count);
  const values = [0.5, -0.25, 0, 1];
  for (const v of values) {
    const b = Buffer.alloc(4);
    b.writeFloatBE(v);
    parts.push(b);
  }
  const r = new FfiReader(new Uint8Array(Buffer.concat(parts)));
  assert.deepEqual(Array.from(r.f32Array()), values);
  assert.equal(r.remaining, 0);
});

test("FfiWriter round-trips an f32Array, taking arrays or Float32Array", () => {
  const values = [0, 1, -1, 0.5, -0.25];
  for (const input of [values, Float32Array.from(values)]) {
    const bytes = new FfiWriter().f32Array(input).f64(48_000).done();
    assert.equal(bytes.length, 4 + values.length * 4 + 8);
    const r = new FfiReader(bytes);
    assert.deepEqual(Array.from(r.f32Array()), values);
    assert.equal(r.f64(), 48_000);
    assert.equal(r.remaining, 0);
  }
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

// FfiWriter is the encoder for the options payloads a model reads off Swift's
// FFIReader, so the two must agree byte for byte.

test("FfiWriter matches the reference big-endian encoding", () => {
  const ref = buildPayload();
  ref.u32(5);
  ref.f64(3.5);
  ref.str("héllo");
  const w = new FfiWriter().u32(5).f64(3.5).str("héllo");
  assert.deepEqual(Array.from(w.done()), Array.from(ref.done()));
  assert.equal(w.length, ref.done().length);
});

test("FfiWriter round-trips through FfiReader", () => {
  const bytes = new FfiWriter()
    .u32(3)
    .f64(0.6)
    .str("EMAIL")
    .strings(["GIVEN_NAME", "SURNAME"])
    .blob(new Uint8Array([1, 2, 3]))
    .done();
  const r = new FfiReader(bytes);
  assert.equal(r.u32(), 3);
  assert.equal(r.f64(), 0.6);
  assert.equal(r.str(), "EMAIL");
  assert.equal(r.u32(), 2);                       // strings() writes a count first
  assert.equal(r.str(), "GIVEN_NAME");
  assert.equal(r.str(), "SURNAME");
  assert.equal(r.u32(), 3);                       // blob() length prefix
  assert.deepEqual(Array.from(r.bytes(3)), [1, 2, 3]);
  assert.equal(r.remaining, 0);
});

test("FfiWriter encodes the two model option payloads", () => {
  // Emo: u32 limit, u32 skinTone (Sources/Emo/Binding.swift).
  const emo = new FfiReader(new FfiWriter().u32(5).u32(3).done());
  assert.equal(emo.u32(), 5);
  assert.equal(emo.u32(), 3);
  assert.equal(emo.remaining, 0);

  // Redact: f64 minimumConfidence, then u32 count + names
  // (Sources/Redact/Binding.swift). An empty label set means the SDK defaults.
  const redact = new FfiReader(new FfiWriter().f64(0.75).strings([]).done());
  assert.equal(redact.f64(), 0.75);
  assert.equal(redact.u32(), 0);
  assert.equal(redact.remaining, 0);
});
