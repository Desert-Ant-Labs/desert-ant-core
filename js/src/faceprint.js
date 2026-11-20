// Faceprints: what Face makes for every face, and Eye with `faceprints`. Pure
// JavaScript, so a faceprint compares and stores without either model, and both
// packages return this one class.
/** How sure a match must be: the cosine similarity at or above which two faceprints are one person. */
export const Level = Object.freeze({
  /** One false match in 1,000 pairs of different people: albums, search, suggestions. */
  recommended: 0.4129,
  /** One false match in 10,000: anything that acts without asking. */
  strict: 0.5116,
});

function cutoff(level) {
  const c = typeof level === "number" ? level : Level[level ?? "recommended"];
  if (c === undefined) throw new TypeError(`unknown level "${level}" (expected "recommended" or "strict")`);
  return c;
}

function fromBase64(s) {
  if (typeof Buffer !== "undefined") return new Uint8Array(Buffer.from(s, "base64"));
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function toBase64(bytes) {
  if (typeof Buffer !== "undefined") return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString("base64");
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

/**
 * One face's identity: 128 numbers of unit length. Two faceprints of the same
 * person point the same way. Store a faceprint with `JSON.stringify` or as `data`
 * (512 bytes), and compare faceprints later without the model. Compare
 * faceprints of one `model` only.
 */
export class Faceprint {
  /** @param {ArrayLike<number>} values @param {string} [model] */
  constructor(values, model = "face-1") {
    const v = Float32Array.from(values);
    let n = 0;
    for (const x of v) n += x * x;
    n = Math.sqrt(n);
    if (n > 0) for (let i = 0; i < v.length; i++) v[i] /= n;
    this.values = v;
    this.model = model;
  }

  /** The values as 512 bytes, little-endian float32. */
  get data() {
    const out = new Uint8Array(this.values.length * 4);
    const view = new DataView(out.buffer);
    this.values.forEach((x, i) => view.setFloat32(i * 4, x, true));
    return out;
  }

  /** A faceprint from `data` and the `model` it was stored with. */
  static fromData(data, model) {
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
    if (bytes.length === 0 || bytes.length % 4 !== 0) throw new TypeError("faceprint data must be whole float32 values");
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const values = new Float32Array(bytes.length / 4);
    for (let i = 0; i < values.length; i++) values[i] = view.getFloat32(i * 4, true);
    const f = Object.create(Faceprint.prototype);
    f.values = values;
    f.model = model;
    return f;
  }

  /** From its JSON form, `{ model, data }` with `data` in base64. */
  static fromJSON(json) {
    const j = typeof json === "string" ? JSON.parse(json) : json;
    return Faceprint.fromData(fromBase64(j.data), j.model);
  }

  toJSON() {
    return { model: this.model, data: toBase64(this.data) };
  }

  /**
   * One faceprint for a person seen in several photos: the direction of their
   * mean. `null` for an empty list or faceprints of different models.
   */
  static average(faceprints) {
    if (!faceprints.length) return null;
    const { model, values } = faceprints[0];
    if (faceprints.some((f) => f.model !== model || f.values.length !== values.length)) return null;
    const sum = new Float32Array(values.length);
    for (const f of faceprints) for (let i = 0; i < sum.length; i++) sum[i] += f.values[i];
    return new Faceprint(sum, model);
  }

  /** Cosine similarity, -1..1. 0 for faceprints of different lengths, which come from different embedders. */
  similarity(other) {
    if (this.values.length !== other.values.length) return 0;
    let s = 0;
    for (let i = 0; i < this.values.length; i++) s += this.values[i] * other.values[i];
    return s;
  }

  /** Whether `other` is the same person at `level` ("recommended" or "strict"). */
  isSamePerson(other, level = "recommended") {
    return this.isComparable(other) && this.similarity(other) >= cutoff(level);
  }

  /** Whether `other` comes from the same embedder: the same model and length. */
  isComparable(other) {
    return this.model === other.model && this.values.length === other.values.length;
  }
}

/**
 * Every faceprint that matches `reference` at `level`, most similar first, as
 * `{ index, similarity }`. For "every photo of Noor" from a selfie or a few
 * tagged photos (`Faceprint.average`).
 */
export function matches(reference, faceprints, { level = "recommended" } = {}) {
  const c = cutoff(level);
  const out = [];
  faceprints.forEach((f, index) => {
    if (!f.isComparable(reference)) return;
    const similarity = reference.similarity(f);
    if (similarity >= c) out.push({ index, similarity });
  });
  return out.sort((a, b) => b.similarity - a.similarity);
}
