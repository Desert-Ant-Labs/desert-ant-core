// FNV-1a character n-gram featurizer, ported from src/tongue_training/hashing.py.
//
// Hashing instead of a learned vocabulary is why this package ships no tokenizer:
// given the same normalized string, every platform produces the same bucket
// indices by construction.
//
// Iterated over **Unicode code points**, not UTF-16 code units. Iterating with a
// plain index would split astral characters into surrogate pairs and hash
// something the reference never sees.

const OFFSET_BASIS = 0x811c9dc5;
const PRIME = 0x01000193;

export const NGRAM_ORDERS = [1, 2, 3, 4, 5] as const;
export const offsetBasis = OFFSET_BASIS;
export const prime = PRIME;

/** FNV-1a 32-bit over Unicode code points. */
export function fnv1a(text: string): number {
  let hash = OFFSET_BASIS;
  for (const char of text) {
    hash ^= char.codePointAt(0)!;
    // Math.imul keeps the multiply in 32 bits, which `*` would not.
    hash = Math.imul(hash, PRIME) & 0xffffffff;
  }
  return hash >>> 0;
}

function fnv1aOfCodePoints(codePoints: number[], from: number, until: number): number {
  let hash = OFFSET_BASIS;
  for (let index = from; index < until; index++) {
    hash ^= codePoints[index]!;
    hash = Math.imul(hash, PRIME) & 0xffffffff;
  }
  return hash >>> 0;
}

/**
 * Bucket counts for a normalized string: the bag the model consumes.
 *
 * Each whitespace token is wrapped in `^`/`$` so word-initial and word-final
 * sequences stay distinguishable from word-internal ones. That distinction
 * carries much of the signal — Portuguese `ão$`, Italian `^gli`.
 */
export function buckets(
  text: string,
  numBuckets: number,
  orders: readonly number[] = NGRAM_ORDERS,
): Map<number, number> {
  const counts = new Map<number, number>();
  if (!text) return counts;
  for (const token of text.split(" ")) {
    if (!token) continue;
    const marked = [0x5e, ...[...token].map((c) => c.codePointAt(0)!), 0x24]; // ^ token $
    for (const order of orders) {
      if (order > marked.length) continue;
      for (let start = 0; start + order <= marked.length; start++) {
        const bucket = fnv1aOfCodePoints(marked, start, start + order) % numBuckets;
        counts.set(bucket, (counts.get(bucket) ?? 0) + 1);
      }
    }
  }
  return counts;
}
