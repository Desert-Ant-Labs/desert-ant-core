/// Biases decoding towards caller-supplied phrases (names, jargon).
///
/// When the decoder writes a token, tokens that start or continue a phrase get
/// a logit bonus, so a close second ("SoFi" vs "Sophie") wins. Shallow fusion
/// with a phrase tree, after NVIDIA's GPU-PB (arXiv 2508.07014). Matching is on
/// characters, so any tokenization of a phrase counts, and is case-sensitive.
struct Booster: Sendable {
    /// Bonus for a whole one-word phrase.
    let startBonus: Float
    /// Bonus for finishing a word of a phrase already under way.
    let continueBonus: Float
    /// Bonus for a token inside a phrase word.
    let partialBonus: Float
    /// Only tokens within this many logits of the model's choice are considered.
    let margin: Float
    /// A token further behind than this cannot win.
    var maxBonus: Float { Swift.max(startBonus, continueBonus, partialBonus) }

    private var children: [[Unicode.Scalar: Int32]] = [[:]]
    private var terminal: [Bool] = [false]
    private let pieces: [[Unicode.Scalar]]
    private static let boundary: Unicode.Scalar = "\u{2581}"

    init?(phrases: [String], vocabulary: [String], startBonus: Float = 2.5,
          continueBonus: Float = 4, partialBonus: Float = 4, margin: Float = 6) {
        self.startBonus = startBonus
        self.continueBonus = continueBonus
        self.partialBonus = partialBonus
        self.margin = margin
        pieces = vocabulary.map { Array($0.unicodeScalars) }
        var added = 0
        for phrase in phrases {
            let words = phrase.split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { continue }
            var node = 0
            for scalar in (String(Self.boundary) + words.joined(separator: String(Self.boundary))).unicodeScalars {
                if let next = children[node][scalar] {
                    node = Int(next)
                } else {
                    children.append([:])
                    terminal.append(false)
                    children[node][scalar] = Int32(children.count - 1)
                    node = children.count - 1
                }
            }
            terminal[node] = true
            added += 1
        }
        guard added > 0 else { return nil }
    }

    /// Tree nodes reached by the tokens so far.
    typealias State = [Int32]

    /// Whether two tokens differ only in case ("▁and", "▁And").
    func sameButCase(_ a: Int, _ b: Int) -> Bool {
        a >= 0 && b >= 0 && a < pieces.count && b < pieces.count && a != b
            && String(String.UnicodeScalarView(pieces[a])).lowercased()
            == String(String.UnicodeScalarView(pieces[b])).lowercased()
    }

    struct Step {
        var bonus: Float = 0
        var next: State = []
        /// A match stands at the end of a phrase word. Not final until the next
        /// token closes the word ("SoFi" + "e" is "SoFie").
        var finishedWord = false
        /// Continued a match already under way.
        var continued = false
    }

    /// The bonus for `token` from `state`; `chosen` is the model's own pick.
    func step(_ state: State, token: Int, chosen: Int = -1) -> Step {
        var out = Step()
        guard token < pieces.count else { return out }
        let piece = pieces[token]
        var starts = state
        if piece.first == Self.boundary { starts.append(0) }
        for start in starts {
            var node = Int(start)
            var ok = true
            var completed = false
            var letters = 0
            for (i, scalar) in piece.enumerated() {
                if let child = children[node][scalar] {
                    node = Int(child)
                    if scalar != Self.boundary { letters += 1 }
                } else if terminal[node] && i > 0 && Self.isTrailing(piece[i...]) {
                    completed = true      // phrase ends inside the token: "Seiko."
                    break
                } else {
                    ok = false
                    break
                }
            }
            guard ok else { continue }
            if !completed { out.next.append(Int32(node)) }
            let phraseDone = completed || terminal[node]
            let wordDone = phraseDone || children[node][Self.boundary] != nil
            if wordDone { out.finishedWord = true }
            if start != 0 { out.continued = true }
            let value: Float
            if start != 0 {
                value = wordDone ? continueBonus : partialBonus
            } else if wordDone {
                // The first word of a longer phrase ("The" of "The Home Depot")
                // is usually just that word, so it gets nothing.
                value = phraseDone ? startBonus : 0
            } else {
                // Not for single letters, or for recasing the model's own word
                // ("and" -> "And" of "Android").
                value = letters >= 2 && !sameButCase(token, chosen) ? partialBonus : 0
            }
            out.bonus = Swift.max(out.bonus, value)
        }
        return out
    }

    /// The fate of a word the bias started.
    enum Verdict: Equatable {
        case pending
        /// Ended as a phrase word: keep it.
        case confirmed
        /// Left the phrase or ended early: roll back to avoid a hybrid ("SoFie").
        case abandoned
    }

    /// The verdict after the next written `token`. `atWordEnd` is the previous
    /// step's `finishedWord`.
    func verdict(after token: Int, _ step: Step, atWordEnd: Bool) -> Verdict {
        // A new word, or punctuation outside the phrase, closes the word;
        // punctuation inside it ("McDonald's", "St. Jude") continues it.
        if startsWord(token) || (!step.continued && endsWord(token)) {
            return atWordEnd ? .confirmed : .abandoned
        }
        return step.continued ? .pending : .abandoned
    }

    /// Whether `token` starts a new word.
    func startsWord(_ token: Int) -> Bool {
        token >= 0 && token < pieces.count && pieces[token].first == Self.boundary
    }

    /// The verdict when the window ends with the word still open.
    func verdictAtEnd(atWordEnd: Bool) -> Verdict {
        atWordEnd ? .confirmed : .abandoned
    }

    /// Whether `token` starts a new word or is punctuation.
    func endsWord(_ token: Int) -> Bool {
        guard token >= 0, token < pieces.count, let first = pieces[token].first else { return false }
        return first == Self.boundary || Self.isTrailing(pieces[token][...])
    }

    private static func isTrailing(_ rest: ArraySlice<Unicode.Scalar>) -> Bool {
        rest.allSatisfy { ".,?!:;'".unicodeScalars.contains($0) }
    }
}
