// The head. No inference runtime and none needed: a detection is an int8
// embedding gather, a sum over the n-grams present, one small matmul and a masked
// softmax — a few thousand multiply-adds. That is why this package has no wasm
// blob and no LiteRT dependency, unlike emo's browser path.
//
// Byte layout of tongue_int8.bin, written by scripts/build_release.py:
//
//   [0]                int8   embedding, numBuckets * dim, row-major
//   [numBuckets*dim]   fp32   linear weight, labels * dim, row-major
//   [+ labels*dim*4]   fp32   linear bias, labels
//
// fp32 fields are little-endian.

import { buckets, NGRAM_ORDERS } from "./hashing.js";

export interface Metadata {
  readonly labels: readonly string[];
  readonly num_buckets: number;
  readonly dim: number;
  readonly ngram_orders: readonly number[];
  readonly embed_scale: number;
  readonly latin_labels?: readonly string[];
}

export interface Prediction {
  /** ISO 639-1 or 639-3 code. */
  readonly language: string;
  readonly probability: number;
}

export class Weights {
  private readonly embedding: Int8Array;
  private readonly linearWeight: Float32Array;
  private readonly linearBias: Float32Array;
  private readonly labels: readonly string[];
  private readonly numBuckets: number;
  private readonly dimension: number;
  private readonly orders: readonly number[];
  private readonly scale: number;

  constructor(bytes: Uint8Array, metadata: Metadata) {
    const labelCount = metadata.labels.length;
    const embeddingCount = metadata.num_buckets * metadata.dim;
    const weightCount = labelCount * metadata.dim;
    const expected = embeddingCount + (weightCount + labelCount) * 4;
    if (bytes.byteLength !== expected) {
      throw new Error(
        `weights are ${bytes.byteLength} bytes, expected ${expected} for this metadata`,
      );
    }
    this.embedding = new Int8Array(bytes.buffer, bytes.byteOffset, embeddingCount);
    // A DataView rather than Float32Array: the fp32 sections are not guaranteed
    // to start on a 4-byte boundary, and a typed-array view would throw.
    const view = new DataView(bytes.buffer, bytes.byteOffset);
    let offset = embeddingCount;
    this.linearWeight = new Float32Array(weightCount);
    for (let i = 0; i < weightCount; i++, offset += 4) {
      this.linearWeight[i] = view.getFloat32(offset, true);
    }
    this.linearBias = new Float32Array(labelCount);
    for (let i = 0; i < labelCount; i++, offset += 4) {
      this.linearBias[i] = view.getFloat32(offset, true);
    }
    this.labels = metadata.labels;
    this.numBuckets = metadata.num_buckets;
    this.dimension = metadata.dim;
    this.orders = metadata.ngram_orders ?? NGRAM_ORDERS;
    this.scale = metadata.embed_scale;
  }

  /**
   * Top-`topK` languages for already-normalized text, decoded over `allowed`.
   *
   * The mask is how the router composes with the head: Cyrillic input competes
   * among the Cyrillic labels, not all 59. Excluded labels get probability zero
   * and the remaining mass renormalizes over the candidates.
   */
  rank(text: string, allowed: ReadonlySet<string>, topK: number): Prediction[] {
    const { dimension } = this;
    const pooled = new Float32Array(dimension);
    // Ascending bucket order, and float32 arithmetic throughout. Both matter for
    // matching the other ports: float addition is not associative, so the
    // accumulation order is part of the answer, and Swift and Kotlin hold the
    // scale and the running sums in float32 while JavaScript numbers are float64.
    // `Math.fround` is what makes a JavaScript multiply round the way theirs does.
    // See the note in Sources/Tongue/Model.swift.
    const scale32 = Math.fround(this.scale);
    const ordered = [...buckets(text, this.numBuckets, this.orders)].sort((a, b) => a[0] - b[0]);
    for (const [bucket, count] of ordered) {
      const base = bucket * dimension;
      const weight = Math.fround(count * scale32);
      for (let index = 0; index < dimension; index++) {
        // pooled is a Float32Array, so the store already rounds; the multiply is
        // what needs forcing.
        pooled[index]! += Math.fround(this.embedding[base + index]! * weight);
      }
    }

    const logits: Array<[string, number]> = [];
    for (let labelIndex = 0; labelIndex < this.labels.length; labelIndex++) {
      const label = this.labels[labelIndex]!;
      if (!allowed.has(label)) continue;
      let sum = this.linearBias[labelIndex]!;
      const base = labelIndex * dimension;
      for (let index = 0; index < dimension; index++) {
        sum = Math.fround(sum + Math.fround(this.linearWeight[base + index]! * pooled[index]!));
      }
      logits.push([label, sum]);
    }
    if (logits.length === 0) return [];

    let maximum = -Infinity;
    for (const [, value] of logits) if (value > maximum) maximum = value;
    // The shift is a float32 subtraction in Swift and Kotlin (`Float - Float`,
    // widened only for `exp`), so it has to be one here too — without the fround
    // this line alone moved the answer by ~1e-10.
    const exponentiated = logits.map(
      ([label, value]) => [label, Math.exp(Math.fround(value - maximum))] as const,
    );
    const total = exponentiated.reduce((sum, [, value]) => sum + value, 0);
    return exponentiated
      .sort((a, b) => b[1] - a[1])
      .slice(0, topK)
      .map(([language, value]) => ({ language, probability: total > 0 ? value / total : 0 }));
  }
}
