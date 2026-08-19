#if canImport(CoreML)
import Foundation

/// A word and when it starts, in seconds from the beginning of the audio.
public struct Word: Sendable, Equatable, Codable {
    public let text: String
    public let start: TimeInterval

    public init(text: String, start: TimeInterval) {
        self.text = text
        self.start = start
    }
}

/// Group sentencepiece pieces into words, timed by the frame that emitted the
/// first piece of each word.
///
/// TDT states how far to advance after every emission, so the frame a token came
/// from is known exactly rather than inferred. Accuracy is bounded by the frame
/// period: one encoder frame is 80 ms, so a word time can only land on a frame
/// boundary. Measured against an independent forced aligner over 300 utterances,
/// word starts are within 80 ms of the reference 63% of the time and within
/// 200 ms 94% of the time (MAE 76 ms), and about half of that residual is the
/// frame grid rather than the model.
func timedWords(tokens: [Int], frames: [Int], vocabulary: [String],
                secondsPerFrame: Double, timeOffset: Double) -> [Word] {
    var out: [Word] = []
    var current = ""
    var currentFrame = 0

    func flush() {
        guard !current.isEmpty else { return }
        out.append(Word(text: current, start: Double(currentFrame) * secondsPerFrame + timeOffset))
        current = ""
    }

    for (i, token) in tokens.enumerated() where token >= 0 && token < vocabulary.count {
        let piece = vocabulary[token]
        // Control pieces such as a language tag are not words.
        if piece.hasPrefix("<") && piece.hasSuffix(">") { continue }
        if piece.hasPrefix("\u{2581}") { flush() }
        if current.isEmpty { currentFrame = i < frames.count ? frames[i] : 0 }
        current += piece.replacingOccurrences(of: "\u{2581}", with: "")
    }
    flush()
    return out
}

/// Join two windows that overlap in time.
///
/// Consecutive windows share up to `boundarySearch` seconds of audio, so both
/// transcribe the speech around the seam. Cutting purely on time duplicates any
/// word whose two estimates straddle the boundary -- the emission times differ
/// by a frame or two between windows -- which is where "they they walked" comes
/// from.
///
/// Instead the overlap is aligned: the longest run of words both windows agree
/// on becomes the splice point, so each word survives exactly once and the
/// transition happens where the two transcripts actually meet. When they agree
/// on nothing, fall back to cutting at the boundary.
func spliceOverlap(_ previous: [Word], _ next: [Word], boundary: TimeInterval,
                   overlap: TimeInterval) -> [Word] {
    guard !previous.isEmpty, !next.isEmpty else { return previous + next }
    let from = boundary - overlap
    let tail = previous.enumerated().filter { $0.element.start >= from }
    let head = next.enumerated().filter { $0.element.start < boundary + overlap }
    guard !tail.isEmpty, !head.isEmpty else {
        return previous.filter { $0.start < boundary } + next.filter { $0.start >= boundary }
    }

    // Longest run of words the two windows agree on. Two constraints keep the
    // alignment honest, and both were learned by measurement: a single matching
    // word is not evidence -- "the" appears everywhere, and splicing on one
    // dropped 181 words over half an hour -- and the time tolerance has to be
    // tight enough that a word cannot match a different occurrence of itself
    // seconds away.
    var best = (length: 0, tailAt: 0, headAt: 0, drift: Double.greatestFiniteMagnitude)
    for ti in tail.indices {
        for hi in head.indices {
            var length = 0
            while ti + length < tail.count, hi + length < head.count,
                  matches(tail[ti + length].element, head[hi + length].element,
                          matchTolerance) {
                length += 1
            }
            guard length >= minimumRun else { continue }
            let drift = abs(tail[ti].element.start - head[hi].element.start)
            if length > best.length || (length == best.length && drift < best.drift) {
                best = (length, ti, hi, drift)
            }
        }
    }

    guard best.length >= minimumRun else {
        return previous.filter { $0.start < boundary } + next.filter { $0.start >= boundary }
    }
    // Keep the earlier window's copy of the agreed run: it has real left
    // context, where the later window began cold at the seam.
    let cut = tail[best.tailAt].offset
    let resume = head[best.headAt].offset + best.length
    return Array(previous[..<cut]) + Array(tail[best.tailAt..<min(tail.count, best.tailAt + best.length)]
        .map(\.element)) + Array(next[resume...])
}

/// Words this far apart are different utterances, not two readings of one.
private let matchTolerance: TimeInterval = 1.0
/// A run shorter than this is coincidence rather than alignment.
private let minimumRun = 2

private func matches(_ a: Word, _ b: Word, _ tolerance: TimeInterval) -> Bool {
    abs(a.start - b.start) <= tolerance && fold(a.text) == fold(b.text)
}

/// Compare words the way a reader would: ignoring case and edge punctuation, so
/// a window that starts mid-sentence and capitalises its first word still aligns.
private func fold(_ s: String) -> String {
    String(s.lowercased().unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0) || $0 == "'"
    })
}

func detokenize(_ pieces: [String]) -> String {
    pieces.joined()
        .replacingOccurrences(of: "\u{2581}", with: " ")
        .trimmingCharacters(in: .whitespaces)
}
#endif
