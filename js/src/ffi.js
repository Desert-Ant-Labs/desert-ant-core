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
