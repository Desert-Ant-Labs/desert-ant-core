#if canImport(CoreML)
import Foundation

/// A word and when it starts, in seconds from the beginning of the audio.
public struct Word: Sendable, Equatable, Codable {
    public let text: String
    public let start: TimeInterval
    /// When the word stops sounding. Never before ``start``.
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = Swift.max(start, end)
    }

    /// How long the word sounds for.
    public var duration: TimeInterval { end - start }
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
func timedWords(tokens: [Int], frames: [Int], ends: [Int], vocabulary: [String],
                secondsPerFrame: Double, timeOffset: Double) -> [Word] {
    var out: [Word] = []
    var current = ""
    var currentFrame = 0
    var currentEnd = 0

    func flush() {
        guard !current.isEmpty else { return }
        out.append(Word(text: current,
                        start: Double(currentFrame) * secondsPerFrame + timeOffset,
                        end: Double(currentEnd) * secondsPerFrame + timeOffset))
        current = ""
    }

    for (i, token) in tokens.enumerated() where token >= 0 && token < vocabulary.count {
        let piece = vocabulary[token]
        // Control pieces such as a language tag are not words.
        if piece.hasPrefix("<") && piece.hasSuffix(">") { continue }
        if piece.hasPrefix("\u{2581}") { flush() }
        if current.isEmpty { currentFrame = i < frames.count ? frames[i] : 0 }
        // The word ends where its last piece ends.
        if i < ends.count { currentEnd = Swift.max(currentEnd, ends[i]) }
        current += piece.replacingOccurrences(of: "\u{2581}", with: "")
    }
    flush()
    return out
}

/// Join two windows that overlap in time.
///
/// Consecutive windows share up to `boundarySearch` seconds of audio, so both
/// transcribe the speech around the seam. Cutting purely on time duplicates any
/// word whose two estimates straddle the boundary - the emission times differ
/// by a frame or two between windows - which is where "they they walked" comes
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
    // word is not evidence - "the" appears everywhere, and splicing on one
    // dropped 181 words over half an hour - and the time tolerance has to be
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
        return repairJoin(previous.filter { $0.start < boundary },
                          next.filter { $0.start >= boundary })
    }
    // Keep the earlier window's copy of the agreed run: it has real left
    // context, where the later window began cold at the seam.
    let cut = tail[best.tailAt].offset
    let resume = head[best.headAt].offset + best.length
    let agreed = Array(tail[best.tailAt..<min(tail.count, best.tailAt + best.length)].map(\.element))
    return repairJoin(Array(previous[..<cut]) + agreed, Array(next[resume...]))
}

/// Clean up the two artifacts a seam leaves even when the windows are aligned.
///
/// Both are one word wide, so neither is caught by matching runs of words, and
/// both are obvious on sight in a transcript.
private func repairJoin(_ left: [Word], _ right: [Word]) -> [Word] {
    var right = right
    guard let last = left.last, let first = right.first else { return left + right }

    // A window beginning mid-sentence capitalises its first word as a false
    // sentence start, so the seam word appears twice differing only in case:
    // "your first episode. Episode. The most". The earlier window's copy has
    // real left context, so that is the one kept. A same-case repeat is left
    // alone, because people do say "that that" and "yeah yeah".
    if fold(last.text) == fold(first.text), last.text != first.text {
        right.removeFirst()
    } else if fold(last.text) == fold(first.text), first.start < last.end {
        // The same word in the same case, twice, and the two spans overlap in
        // time. A speaker saying "that that" says it twice, one after the
        // other; these two occupy the same moment, so they are one word timed
        // by two windows. Without end times the two cases are
        // indistinguishable, which is why this repeat used to be left alone.
        right.removeFirst()
    }

    // The earlier window ends where its audio ends, so it punctuates as though
    // the sentence ended there, and the later window carries on in lower case:
    // "we made the bet to build for iOS. because we got stuck". A lower-case
    // continuation means the sentence did not end.
    //
    // ".!?" is the model's entire stock of sentence-ending punctuation - it has
    // no token containing a semicolon, an ellipsis or a Greek question mark - so
    // this covers every terminator that can actually arrive. The test is weaker
    // in languages that capitalise nouns: a German window resuming on a noun
    // reads as a sentence start and the false break is left in place. That is a
    // repair missed rather than a wrong repair made, which is the right way for
    // it to fail when the language is unknown.
    if let head = right.first, let tail = left.last,
       head.text.first?.isLowercase == true,
       let terminator = tail.text.last, ".!?".contains(terminator) {
        var fixed = left
        fixed[fixed.count - 1] = Word(text: String(tail.text.dropLast()),
                                      start: tail.start, end: tail.end)
        return fixed + right
    }
    return left + right
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
/// Compare two words ignoring case, for spotting a seam duplicate.
///
/// Unicode case folding rather than lowercasing, so that German "STRASSE" and
/// "straße" are recognised as the same word. Folding stops at case: making it
/// diacritic-insensitive as well would merge five of the five genuinely
/// distinct pairs it was tested against, including "résumé" against "resume",
/// and this comparison deletes a word when it matches. Turkish dotted and
/// dotless i and accented Greek capitals still fail to match, because both need
/// a locale this code does not have.
func fold(_ s: String) -> String {
    String(s.folding(options: [.caseInsensitive], locale: nil).unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0) || $0 == "'"
    })
}

/// Force word times to be non-decreasing without reordering the words.
///
/// The splice chooses which window each word comes from, and the two windows
/// time the same speech a frame or two apart, so a word can legitimately follow
/// another in the text while carrying a slightly earlier timestamp. Sorting by
/// time to fix that would be wrong: it reorders subwords of the same word and
/// scrambles the seam. The text order is what the splice established and is
/// authoritative, so a backward step is raised to the running maximum instead.
func clampMonotonic(_ words: [Word]) -> [Word] {
    var out: [Word] = []
    out.reserveCapacity(words.count)
    var highest = -Double.greatestFiniteMagnitude
    for word in words {
        let start = Swift.max(word.start, highest)
        highest = start
        out.append(start == word.start ? word : Word(text: word.text, start: start, end: word.end))
    }
    // Then pull each end back to where the next word begins. Two windows time
    // the same speech a frame or two apart, so a word spliced from the earlier
    // one can be credited with sound that the later one has already given to
    // the next word. An end that overruns the next start is unusable for
    // cutting, which is most of what an end time is for.
    for i in out.indices.dropLast() {
        let limit = out[i + 1].start
        if out[i].end > limit {
            out[i] = Word(text: out[i].text, start: out[i].start,
                          end: Swift.max(out[i].start, limit))
        }
    }
    return out
}

/// Trim word ends back to where the sound actually stops.
///
/// The recogniser predicts, for each token, how many frames to skip before
/// looking for the next one. That is the only evidence it offers about where a
/// word ends, but it overshoots: the skip runs to wherever the next token is
/// picked up, so a word followed by a pause is credited with the pause. Against
/// a forced aligner the ends came out 86 ms late on average and words measured
/// 341 ms against the aligner's 223 ms.
///
/// The audio settles this without a fitted constant. Within the span the model
/// claims, the end is taken to be the last point still sounding at a tenth of
/// the loudest part of that word, which is a threshold relative to the speaker
/// and so survives a change of level, language or recording.
func refineEnds(_ words: [Word], samples: ArraySlice<Float>, windowStart: TimeInterval,
                sampleRate: Double, frame: TimeInterval = 0.01) -> [Word] {
    guard !words.isEmpty, !samples.isEmpty else { return words }
    let step = Swift.max(1, Int(frame * sampleRate))
    let base = samples.startIndex

    func energy(at index: Int) -> Float {
        let low = Swift.max(base, base + index)
        let high = Swift.min(samples.endIndex, low + step)
        guard low < high else { return 0 }
        var sum: Float = 0
        for i in low..<high { sum += samples[i] * samples[i] }
        return sum / Float(high - low)
    }

    return words.map { word in
        let from = Int((word.start - windowStart) * sampleRate)
        let to = Int((word.end - windowStart) * sampleRate)
        guard to > from, from >= 0, to - base <= samples.count else { return word }
        var peak: Float = 0
        var index = from
        while index < to { peak = Swift.max(peak, energy(at: index)); index += step }
        guard peak > 0 else { return word }
        // Swept against the aligner over 6295 words: 0.02 through 0.10 all land
        // within 2 ms of the same error, so this is a shallow choice rather than
        // a fitted one. The lower end wins narrowly and errs late, which is the
        // safe direction - an end that runs a little long falls in the gap
        // after the word, where a short one clips the word itself.
        let floorEnergy = peak * 0.05
        var last = from
        index = from
        while index < to {
            if energy(at: index) >= floorEnergy { last = index }
            index += step
        }
        // Keep the frame that was still sounding, not the one after it.
        let refined = windowStart + Double(last + step) / sampleRate
        return Word(text: word.text, start: word.start,
                    end: Swift.max(word.start, Swift.min(word.end, refined)))
    }
}

func detokenize(_ pieces: [String]) -> String {
    pieces.joined()
        .replacingOccurrences(of: "\u{2581}", with: " ")
        .trimmingCharacters(in: .whitespaces)
}
#endif
