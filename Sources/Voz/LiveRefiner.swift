#if canImport(CoreML)
import CoreML
import Foundation

/// Second-pass revision: re-reads recent speech with the offline graph.
///
/// The streaming path answers in about 200 ms with whatever a few frames of
/// right context support. The offline path sees a whole window at once, and on
/// the same bundle it is the more accurate of the two by a wide margin. A
/// dictation app wants both: text now, and text that is right a moment later.
///
/// So the transcript is built in two layers. Everything older than the last
/// refine is the offline path's answer, everything newer is the streaming
/// path's, and the join moves forward as speech arrives. A word only stops
/// being able to change once a refine has passed over it with enough audio on
/// its right.
///
/// This is why the two graphs are functions of one file rather than two models:
/// they are used together, on the same audio, seconds apart.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *)
final class LiveRefiner {
    /// Audio the offline graph reads per pass. Its window, so one dispatch.
    private let windowSeconds: Double
    /// Speech nearer the end than this is left to the streaming path: it has no
    /// right context yet, so refining it would produce a different answer again
    /// on the next pass and the text would flicker.
    private let volatileTail: Double
    private let sampleRate: Double
    /// Overlap `spliceOverlap` aligns the two passes on. Matches the one the
    /// offline path uses at its own window seams.
    private static let spliceMargin: Double = 3.0

    private let pipeline: Pipeline
    private(set) var words: [Word] = []
    /// The settled prefix, held verbatim.
    ///
    /// ``stable`` is a promise a client builds on: it will not be re-edited. A
    /// time frontier alone cannot keep that promise, because an utterance
    /// shorter than the window is re-read from zero on every pass and the
    /// normalization statistics and attention context both change as more audio
    /// arrives, so even the first word can come out different. Words are
    /// therefore promoted here only once two consecutive passes agree on them
    /// AND they sit behind the splice margin, and once promoted they are
    /// carried rather than recomputed. That makes the guarantee structural
    /// instead of probabilistic.
    private var pinned: [Word] = []
    private var previous: [Word] = []
    /// Audio time before which `words` will not change again.
    private(set) var stableThrough: TimeInterval = 0
    /// Audio time the last pass read up to.
    private(set) var refinedThrough: TimeInterval = 0

    /// How far back a pass reads. The caller needs it to step the frontier
    /// without leaving a gap.
    var contextSeconds: Double { windowSeconds }

    init(assets: Assets, windowSeconds: Double, volatileTail: Double) throws {
        pipeline = try Pipeline(assets: assets)
        self.windowSeconds = windowSeconds
        self.volatileTail = volatileTail
        sampleRate = Double(assets.configuration.sampleRate)
    }

    func reset() {
        words = []
        pinned = []
        previous = []
        stableThrough = 0
        refinedThrough = 0
    }

    /// Re-read the tail of the utterance and splice it into what is held.
    ///
    /// Only the most recent window is re-read, so the cost is flat in the
    /// length of the dictation rather than growing with it: a two minute
    /// utterance refines as cheaply as a five second one.
    func refine(ring: LiveRing, scratch: inout [Float], through: TimeInterval) throws {
        let available = ring.retainedCount
        let end = min(through, Double(available) / sampleRate)
        guard end > refinedThrough || words.isEmpty else { return }
        // How far back a pass reads is the cost, almost exactly: the offline
        // graph runs at about 46x real time, so a 12 s window is ~0.26 s and a
        // 3 s window is ~0.07 s. It is also the accuracy, in the other
        // direction: the same model scores 2.5% on a window it nearly fills and
        // 4.2% on one that is mostly padding, so a short context is a worse
        // second opinion. `windowSeconds` is where that trade is set.
        let start = max(0, end - windowSeconds)
        let low = Int(start * sampleRate)
        let high = min(available, Int(end * sampleRate))
        guard high - low > Int(0.1 * sampleRate) else { return }

        // The whole window is decoded, not just the part still in doubt.
        //
        // Skipping the settled prefix looks like free money: decode is ~290 ms
        // of a ~330 ms pass, because it costs a dispatch per emitted token.
        // Measured, it is not. Starting a decode partway into a window starts
        // the prediction network from a blank state in the middle of a word,
        // and the offline path only gets away with that at its own window seams
        // because it places them at the quietest point it can find. Resuming at
        // the stable frontier took WER from 3.96% to 32.3%; backing the resume
        // point up three seconds so the splice had a run to align on recovered
        // it only to 23.4%.
        //
        // So a pass costs what it costs, and the controls are how often it runs
        // and how far back it reads, not decoding less of it.
        ring.copyRetained(from: low, to: high, into: &scratch)
        guard !scratch.isEmpty else { return }
        let validFrames = Int(ceil(Double(scratch.count) / Double(sampleRate)
                                   / pipeline.secondsPerFrame))
        let produced = try pipeline.refineWindow(scratch[...], validFrames: validFrames,
                                                 fromFrame: 0)
        let shifted = produced.map {
            Word(text: $0.text, start: $0.start + start, end: $0.end + start)
        }
        var candidate: [Word]
        if words.isEmpty || start <= 0 || stableThrough <= start {
            candidate = shifted
        } else {
            // Both passes transcribe the speech around the join, so cutting on
            // time alone duplicates any word whose two estimates straddle it.
            // `spliceOverlap` aligns on the longest run the two agree about,
            // which is the same machinery the offline path uses at its window
            // seams.
            // Splice at the stable frontier rather than at the window start:
            // everything after it is this pass's to replace, and everything
            // before it has already been settled by a pass with more context.
            candidate = spliceOverlap(words, shifted, boundary: stableThrough,
                                      overlap: Self.spliceMargin)
        }
        // Carry the settled prefix through unchanged, and take only what the
        // new pass says about the time after it.
        if let last = pinned.last {
            candidate = pinned + candidate.filter { $0.start >= last.end }
        }
        refinedThrough = end
        stableThrough = max(0, end - volatileTail)
        promote(candidate)
        words = candidate
    }

    /// Grow the settled prefix to what this pass and the last one agree about.
    private func promote(_ candidate: [Word]) {
        let frontier = max(0, stableThrough - Self.spliceMargin)
        var agreed = 0
        while agreed < candidate.count, agreed < previous.count,
              candidate[agreed].text == previous[agreed].text,
              candidate[agreed].end <= frontier {
            agreed += 1
        }
        if agreed > pinned.count {
            pinned = Array(candidate.prefix(agreed))
        }
        previous = candidate
    }

    /// Audio time before which a word can no longer be rewritten.
    ///
    /// Behind ``stableThrough``, not equal to it. `spliceOverlap` aligns the two
    /// passes on the longest run they agree about *within* `spliceMargin` of the
    /// boundary, so a word inside that margin can still be replaced by the next
    /// pass even though it sits before the frontier. Promising it is final is a
    /// promise the next splice can break, which a client using ``stable`` to
    /// avoid re-editing would see as corruption.

    /// Words that will not change, and the ones that still might.
    func split() -> (stable: [Word], volatile: [Word]) {
        (pinned, Array(words.dropFirst(pinned.count)))
    }
}
#endif
