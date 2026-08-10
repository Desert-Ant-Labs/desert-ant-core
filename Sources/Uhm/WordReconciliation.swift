// Pure geometry over ASR word ranges and detected fillers; no platform
// dependencies, so it runs everywhere the module builds.

/// A timestamped word from an ASR transcript.
///
/// Field names match WhisperKit's `WordTiming` (`word`, `start`, `end`) so the
/// mapping is trivial:
///
/// ```swift
/// let words = segment.words?.map {
///     WordRange(start: Double($0.start), end: Double($0.end), word: $0.word)
/// } ?? []
/// ```
///
/// Float → Double conversion stays the caller's job — keeps this type free
/// of a hard WhisperKit dependency and lets non-Whisper ASR sources (Apple
/// `SFSpeechRecognizer`, Deepgram, AssemblyAI, etc.) map in equally easily.
public struct WordRange: Sendable, Equatable {
    /// Word start time, in seconds.
    public var start: Double
    /// Word end time, in seconds.
    public var end:   Double
    /// The transcribed word text.
    public var word:  String

    /// Creates a timestamped word.
    public init(start: Double, end: Double, word: String) {
        self.start = start
        self.end = end
        self.word = word
    }

    /// Word length in seconds (`end - start`).
    public var duration: Double { end - start }
}

/// Knobs for `Uhm.reconcileWords`. The defaults match DuoKit's production use:
/// only adjust words with substantial filler overlap, and emit one timestamp
/// per word rather than fragments.
public struct ReconcileOptions: Sendable {
    /// Minimum overlap fraction — overlap_seconds / piece_duration — before a
    /// (piece, filler) pair triggers an adjustment. Below this the pair is
    /// ignored. Default 0.5.
    ///
    /// Lower it (e.g. 0.2) to be more aggressive about trimming, at the cost
    /// of being sensitive to ASR boundary jitter. Raise it to 0.7+ to only
    /// touch obvious cases.
    public var minOverlapFraction: Double = 0.5

    /// When a word strictly contains a filler, emit *both* the pre- and
    /// post-filler halves if true; emit only the longer half if false.
    /// Default false — most consumers want one timestamp per word.
    public var splitContainedWords: Bool = false

    /// Creates reconciliation options.
    /// - Parameters:
    ///   - minOverlapFraction: Minimum overlap fraction before a (word, filler)
    ///     pair is adjusted. Default `0.5`.
    ///   - splitContainedWords: Emit both halves when a word contains a filler.
    ///     Default `false`.
    public init(minOverlapFraction: Double = 0.5,
                splitContainedWords: Bool = false) {
        self.minOverlapFraction = minOverlapFraction
        self.splitContainedWords = splitContainedWords
    }
}

public extension Uhm {
    /// Reconcile ASR word ranges with detected filler ranges so cuts can be
    /// applied without clipping word audio.
    ///
    /// Whisper (and most ASR) emits a single word range whose boundaries can
    /// straddle, contain, or live inside a filler. Naïvely dropping any word
    /// that overlaps a filler loses ~30 % of detections (the INSIDE-class
    /// case where Whisper transcribes the filler as a word); naïvely cutting
    /// at filler boundaries clips real audio. This function applies five
    /// geometric rules per (word, overlapping filler) pair:
    ///
    /// - **Word fully inside filler** → drop the word. Whisper transcribed
    ///   the filler as a real word.
    /// - **Word leaks into filler from before** → trim the word's end to
    ///   `filler.start`.
    /// - **Word leaks out of filler to after** → push the word's start to
    ///   `filler.end`.
    /// - **Word strictly contains the filler** → split into pre- and
    ///   post-filler ranges; emit the longer half (or both, per
    ///   `options.splitContainedWords`).
    /// - **No overlap** → word passes through unchanged.
    ///
    /// Multiple fillers overlapping a single word are applied sequentially,
    /// so a word can split into many pieces if it spans multiple fillers
    /// (with `splitContainedWords = true`).
    ///
    /// The `minOverlapFraction` option gates each rule: an overlap below
    /// the threshold (vs the current word piece's duration) is ignored,
    /// so small ASR-vs-Uhm boundary jitter doesn't trim real words.
    ///
    /// Output is sorted by `start` and filtered of zero/negative durations.
    ///
    /// - Parameters:
    ///   - words:   ASR word ranges. Need not be sorted.
    ///   - fillers: Filler detections — typically `result.fillers` from
    ///              `Uhm.analyze(...)`. Need not be sorted.
    ///   - options: See `ReconcileOptions`.
    /// - Returns: Reconciled word ranges, sorted by `start`.
    static func reconcileWords(
        _ words: [WordRange],
        fillers: [Detection],
        options: ReconcileOptions = .init()
    ) -> [WordRange] {
        if fillers.isEmpty {
            return words
                .filter { $0.end > $0.start }
                .sorted { $0.start < $1.start }
        }

        // Sort once; the per-word loop assumes nothing about input order but
        // benefits from sequential filler order for the "skip non-overlapping"
        // micro-optimisation below.
        let sortedFillers = fillers.sorted { $0.start < $1.start }
        var output: [WordRange] = []
        output.reserveCapacity(words.count)

        for word in words {
            // Start with the original word as a single piece. Each filler may
            // shrink, drop, or split the current pieces; later fillers see
            // the already-modified set.
            var pieces: [WordRange] = [word]

            for filler in sortedFillers {
                // Fillers are start-ascending: once one starts past the
                // rightmost piece, no later filler can overlap this word.
                if let lastEnd = pieces.last?.end, filler.start >= lastEnd {
                    break
                }
                // Cheap reject: filler ended before the leftmost piece.
                if let firstStart = pieces.first?.start, filler.end <= firstStart {
                    continue
                }

                var next: [WordRange] = []
                next.reserveCapacity(pieces.count)

                for piece in pieces {
                    let dur = piece.duration
                    if dur <= 0 { continue }

                    let overlapStart = Swift.max(piece.start, filler.start)
                    let overlapEnd   = Swift.min(piece.end,   filler.end)
                    let overlap = overlapEnd - overlapStart

                    if overlap <= 0 {
                        next.append(piece); continue
                    }

                    let pieceInsideFiller = filler.start <= piece.start && filler.end >= piece.end
                    let pieceContainsFiller = piece.start < filler.start && piece.end > filler.end
                    let leaksFromBefore = piece.start < filler.start && piece.end <= filler.end
                    let leaksToAfter    = piece.start >= filler.start && piece.end > filler.end

                    // The fraction gate absorbs ASR-vs-filler boundary jitter on partial
                    // (leak) overlaps only. Full containment is unambiguous — a stretched
                    // word enclosing a filler has a small overlap *because* it is
                    // over-extended, the case we most want to split.
                    if (leaksFromBefore || leaksToAfter), overlap / dur < options.minOverlapFraction {
                        next.append(piece); continue
                    }

                    if pieceInsideFiller {
                        // Drop: Whisper-as-word-of-filler. Don't append.
                    } else if pieceContainsFiller {
                        let pre  = WordRange(start: piece.start, end: filler.start, word: piece.word)
                        let post = WordRange(start: filler.end,  end: piece.end,    word: piece.word)
                        if options.splitContainedWords {
                            if pre.duration  > 0 { next.append(pre)  }
                            if post.duration > 0 { next.append(post) }
                        } else {
                            let longer = pre.duration >= post.duration ? pre : post
                            if longer.duration > 0 { next.append(longer) }
                        }
                    } else if leaksFromBefore {
                        next.append(WordRange(start: piece.start, end: filler.start, word: piece.word))
                    } else if leaksToAfter {
                        next.append(WordRange(start: filler.end, end: piece.end, word: piece.word))
                    } else {
                        // Shouldn't be reachable given the four exhaustive cases
                        // when overlap > 0. Pass through defensively.
                        next.append(piece)
                    }
                }
                pieces = next
                if pieces.isEmpty { break }
            }

            output.append(contentsOf: pieces)
        }

        return output
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
    }
}
