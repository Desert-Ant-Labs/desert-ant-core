// FfiReader: a big-endian cursor over the length-prefixed typed buffer the
// native core returns. It is the JavaScript counterpart of Kotlin's FfiReader
// and the Swift `FFIWriter`/`FFIBuffer` format in desert-ant-core: values are
// big-endian, doubles are IEEE-754, and strings are a uint32 byte length
// followed by UTF-8. A model reads its own payload schema off this cursor.
//
// Uses DataView (not node Buffer), so it works unchanged in the browser too;
// the per-model node package uses it via `decodeResult` (native.js), which
// strips the outer uint32 length prefix and hands back a reader over the body.
export class FfiReader {
  constructor(bytes) {
    this._bytes = bytes;
    this._view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    this._o = 0;
  }

  u32() {
    const v = this._view.getUint32(this._o, false);
    this._o += 4;
    return v;
  }

  i32() {
    const v = this._view.getInt32(this._o, false);
    this._o += 4;
    return v;
  }

  f64() {
    const v = this._view.getFloat64(this._o, false);
    this._o += 8;
    return v;
  }

  /** Read `n` raw bytes (a view into the underlying buffer; copy if retaining). */
  bytes(n) {
    const v = this._bytes.subarray(this._o, this._o + n);
    this._o += n;
    return v;
  }

  /** Read a uint32-length-prefixed UTF-8 string. */
  str() {
    const n = this.u32();
    const s = new TextDecoder().decode(this._bytes.subarray(this._o, this._o + n));
    this._o += n;
    return s;
  }

  get offset() {
    return this._o;
  }

  get remaining() {
    return this._bytes.length - this._o;
  }
}

// FfiWriter: the other direction, for the arguments a host passes in. It is the
// counterpart of Swift's `FFIReader` (Sources/FFIBuffer): a model's options cross
// the generic `dal_run` ABI as a payload the model decodes itself, which is what
// lets one C symbol serve every model. Same encoding as FfiReader reads.
export class FfiWriter {
  constructor() {
    this._parts = [];
    this._length = 0;
  }

  _push(bytes) {
    this._parts.push(bytes);
    this._length += bytes.length;
    return this;
  }

  /** Append a big-endian uint32. */
  u32(v) {
    const b = new Uint8Array(4);
    new DataView(b.buffer).setUint32(0, v >>> 0, false);
    return this._push(b);
  }

  /** Append a big-endian IEEE-754 double. */
  f64(v) {
    const b = new Uint8Array(8);
    new DataView(b.buffer).setFloat64(0, v, false);
    return this._push(b);
  }

  /** Append a uint32 UTF-8 byte count, then the UTF-8 bytes. */
  str(s) {
    const utf8 = new TextEncoder().encode(String(s ?? ""));
    return this.u32(utf8.length)._push(utf8);
  }

  /** Append a uint32 count, then that many length-prefixed strings. */
  strings(values) {
    const list = Array.from(values ?? []);
    this.u32(list.length);
    for (const s of list) this.str(s);
    return this;
  }

  /** Append a uint32 byte count, then the raw bytes. */
  blob(bytes) {
    const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    return this.u32(b.length)._push(b);
  }

  /** Append raw bytes verbatim (no length prefix). */
  raw(bytes) {
    return this._push(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes));
  }

  get length() {
    return this._length;
  }

  /** The finished payload (no outer length prefix; `dal_run` takes ptr + len). */
  done() {
    const out = new Uint8Array(this._length);
    let o = 0;
    for (const part of this._parts) {
      out.set(part, o);
      o += part.length;
    }
    return out;
  }
}
