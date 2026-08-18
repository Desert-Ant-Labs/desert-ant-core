import Foundation

// FNV-1a character n-gram featurizer, ported from src/tongue_training/hashing.py.
//
// Hashing instead of a learned vocabulary is the reason this SDK needs no model
// file beyond the weights and no tokenizer at all. A vocab file would mean BPE
// merge-order drift, unknown-token policy differences and three subtly
// disagreeing implementations. A pinned hash has none of that: given the same
// normalized string, every platform produces the same bucket indices by
// construction.
//
// Iterated over **Unicode scalar values** — not UTF-8 bytes, not UTF-16 code
// units. Scalars are the only unit Swift, Kotlin and JavaScript agree on without
// extra work, and getting this wrong silently shifts every feature.

public enum Hashing {
    public static let offsetBasis: UInt32 = 0x811C_9DC5
    public static let prime: UInt32 = 0x0100_0193
    public static let ngramOrders = [1, 2, 3, 4, 5]

    private static let boundaryStart: Unicode.Scalar = "^"
    private static let boundaryEnd: Unicode.Scalar = "$"

    /// FNV-1a 32-bit over Unicode scalar values.
    public static func fnv1a(_ text: String) -> UInt32 {
        var hash = offsetBasis
        for scalar in text.unicodeScalars {
            hash ^= scalar.value
            hash = hash &* prime          // &* : wrapping, which is the 32-bit mask
        }
        return hash
    }

    /// FNV-1a over a scalar slice, so n-gram extraction needs no substring allocation.
    static func fnv1a(_ scalars: ArraySlice<Unicode.Scalar>) -> UInt32 {
        var hash = offsetBasis
        for scalar in scalars {
            hash ^= scalar.value
            hash = hash &* prime
        }
        return hash
    }

    /// Bucket counts for a normalized string: the bag the model consumes.
    ///
    /// Each whitespace token is wrapped in `^`/`$` so word-initial and word-final
    /// sequences stay distinguishable from word-internal ones. That distinction
    /// carries much of the signal — Portuguese `ão$`, Italian `^gli`.
    public static func buckets(
        _ text: String,
        numBuckets: Int,
        orders: [Int] = ngramOrders
    ) -> [Int: Int] {
        guard !text.isEmpty else { return [:] }
        var counts: [Int: Int] = [:]
        // Split on Unicode scalars, not Characters. `components(separatedBy:)` and
        // `split` both work in grapheme clusters, and a space followed by a
        // combining mark is ONE cluster — so a token starting with a mark (Devanagari
        // virama, Arabic fatha, common once a hashtag's leading letters are stripped)
        // silently swallowed its own boundary here, while Kotlin's `split(" ")` and
        // JavaScript's `split(" ")` both cut on the code unit. Same normalized bytes,
        // different tokens, different n-grams, different answer.
        for token in text.unicodeScalars.split(separator: " ", omittingEmptySubsequences: true) {
            var marked = [boundaryStart]
            marked.append(contentsOf: token)
            marked.append(boundaryEnd)
            for order in orders where order <= marked.count {
                for start in 0...(marked.count - order) {
                    let bucket = Int(fnv1a(marked[start..<(start + order)]) % UInt32(numBuckets))
                    counts[bucket, default: 0] += 1
                }
            }
        }
        return counts
    }
}
