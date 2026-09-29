#if canImport(CoreML)
import AudioIO
import Foundation

public extension Voz {
    /// Tuning for a live session. The defaults trade a second of latency for
    /// stable text; a caller that wants snappier tentative words can lower
    /// `updateInterval` and pay proportionally more compute.
    struct LiveConfiguration: Sendable {
        /// How much new audio accumulates before the tail is transcribed again.
        public var updateInterval: TimeInterval = 1.0
        /// Once the held audio is this long, what precedes the last committed
        /// word is released at a quiet point. Kept under the model's 15 s
        /// window so the tail always fits in one, where transcription is a
        /// single encode.
        public var commitAfter: TimeInterval = 10
        /// The safety valve for speech the passes never agree on: a word this
        /// far behind "now" is committed even without agreement, so nonstop
        /// contested audio cannot pin the tail against the window limit.
        public var holdback: TimeInterval = 3
        /// How far apart two passes may place a word's start and still be the
        /// same word. A frame is 80 ms; this allows a couple of frames of
        /// wobble from the re-crop.
        public var agreementTolerance: TimeInterval = 0.25

        public init() {}

        public init(updateInterval: TimeInterval, commitAfter: TimeInterval,
                    holdback: TimeInterval) {
            self.updateInterval = updateInterval
            self.commitAfter = commitAfter
            self.holdback = holdback
        }
    }

    /// One step of a live transcription: what is settled, and what may change.
    struct LiveUpdate: Sendable {
        /// Words that are final. Their audio has been released; they will
        /// appear identically in every later update.
        public let committedWords: [Word]
        /// Words for the audio still held, which the next pass may revise.
        public let tentativeWords: [Word]
        /// The last update of a session: everything is in `committedWords`.
        public let isFinal: Bool

        public var committedText: String {
            committedWords.map(\.text).joined(separator: " ")
        }
        public var tentativeText: String {
            tentativeWords.map(\.text).joined(separator: " ")
        }
        /// The whole transcript as it currently stands.
        public var text: String {
            (committedWords + tentativeWords).map(\.text).joined(separator: " ")
        }
    }

    /// Start a live session: feed it microphone samples as they arrive and
    /// read transcript updates within about `updateInterval` of the speech.
    ///
    /// ```swift
    /// let live = voz.liveTranscriber()
    /// Task { for await update in live.updates { show(update.text) } }
    /// // from the audio tap:
    /// await live.append(chunk, sampleRate: format.sampleRate)
    /// // when recording stops:
    /// await live.finish()
    /// ```
    ///
    /// How it works: the model's window is a fixed 15 s, so it cannot decode a
    /// frame at a time. But it transcribes far faster than realtime, so the
    /// session re-runs the audio it is still holding on every update - one
    /// window, one encode - and emits the words as tentative. Once the held
    /// audio approaches the window length, the older words stop changing
    /// between passes; they are committed at a quiet point and their audio is
    /// dropped, which bounds both memory and the cost of every pass.
    nonisolated func liveTranscriber(
        configuration: LiveConfiguration = .init()
    ) -> LiveTranscriber {
        LiveTranscriber(voz: self, configuration: configuration, modelRate: sampleRate)
    }
}

/// A live transcription session over one `Voz` instance. See
/// ``Voz/liveTranscriber(configuration:)``.
public actor LiveTranscriber {
    private let voz: Voz
    private let configuration: Voz.LiveConfiguration
    private let modelRate: Double

    /// Audio still held, at `modelRate`, starting at `bufferStart` seconds
    /// into the session. Reaches back a little before the last committed word
    /// so the next pass has left context.
    private var buffer: [Float] = []
    private var bufferStart: TimeInterval = 0
    private var committed: [Word] = []
    /// Where committed text ends. A pass re-reads audio before this point for
    /// context, and the words it produces there are already spoken for.
    private var committedEnd: TimeInterval = 0
    /// The previous pass's words past `committedEnd`, absolute-timestamped,
    /// for the agreement check.
    private var previous: [Word] = []
    private var samplesSinceRun = 0
    private var running = false
    private var finishRequested = false
    private var done = false

    private let continuation: AsyncStream<Voz.LiveUpdate>.Continuation
    /// Updates in order, ending with one whose `isFinal` is true (after
    /// ``finish()``). One consumer; a fresh session is cheap, so a caller
    /// wanting several should fan out itself.
    public nonisolated let updates: AsyncStream<Voz.LiveUpdate>

    init(voz: Voz, configuration: Voz.LiveConfiguration, modelRate: Double) {
        self.voz = voz
        self.configuration = configuration
        self.modelRate = modelRate
        (updates, continuation) = AsyncStream.makeStream()
    }

    /// Feed captured audio. Mono; any sample rate, resampled here so the audio
    /// tap can hand over whatever format the device produced.
    public func append(_ samples: [Float], sampleRate: Double) {
        guard !finishRequested, !samples.isEmpty else { return }
        let converted = sampleRate == modelRate
            ? samples
            : Resample.linear(samples, from: sampleRate, to: modelRate)
        buffer.append(contentsOf: converted)
        samplesSinceRun += converted.count
        runIfDue()
    }

    /// No more audio is coming. One final pass commits everything held, the
    /// final update is emitted, and `updates` finishes.
    public func finish() {
        guard !finishRequested else { return }
        finishRequested = true
        runIfDue()
    }

    // MARK: - The pass

    private func runIfDue() {
        guard !running, !done else { return }
        let due = finishRequested
            || Double(samplesSinceRun) / modelRate >= configuration.updateInterval
        guard due else { return }
        running = true
        samplesSinceRun = 0
        Task { await runOnce() }
    }

    private func runOnce() async {
        // Snapshot: `append` may extend `buffer` while `transcribe` is away,
        // and those samples belong to the next pass.
        let samples = buffer
        let start = bufferStart

        var words: [Word] = []
        if !samples.isEmpty {
            // A failed pass is retried by the next one with more audio; only a
            // final pass surfaces nothing rather than hanging the stream.
            if let result = try? await voz.transcribe(samples: samples) {
                words = result.words.map {
                    Word(text: $0.text, start: $0.start + start, end: $0.end + start)
                }
            }
        }

        // The pass re-read audio behind `committedEnd` for context; the
        // words it produced there are already committed, in whatever form an
        // earlier pass agreed on. Half the tolerance so a committed word's
        // wobbled re-reading is dropped rather than re-emitted.
        let fresh = words.filter {
            $0.start >= committedEnd - configuration.agreementTolerance / 2
        }

        if finishRequested {
            committed += fresh
            buffer.removeAll()
            done = true
            continuation.yield(Voz.LiveUpdate(committedWords: committed,
                                              tentativeWords: [], isFinal: true))
            continuation.finish()
            running = false
            return
        }

        // Commit the prefix two consecutive passes agree on: the second pass
        // had more trailing context, and the word still came out the same, so
        // more context is not going to change it. This is what streams words
        // out within about one updateInterval of their being spoken, instead
        // of waiting for them to age past a fixed holdback.
        var stable = agreedPrefix(previous, fresh)

        // The safety valve: audio the passes keep disagreeing about must not
        // pin the tail against the 15 s window. Anything well behind "now" is
        // as good as it is going to get, so the latest reading wins.
        let duration = Double(samples.count) / modelRate
        if duration > configuration.commitAfter {
            let deadline = start + duration - configuration.holdback
            for word in fresh.dropFirst(stable.count) where word.end <= deadline {
                stable.append(word)
            }
        }

        if !stable.isEmpty {
            committed += stable
            committedEnd = stable[stable.count - 1].end
        }
        previous = Array(fresh.dropFirst(stable.count))

        release(passed: samples, from: start)
        continuation.yield(Voz.LiveUpdate(committedWords: committed,
                                          tentativeWords: previous, isFinal: false))
        running = false
        // Audio that arrived during the pass, or a finish() that did, may
        // already be due.
        runIfDue()
    }

    /// The words at the front of `current` that `earlier` already produced:
    /// same text, same place in the audio. Timestamps are absolute, so the
    /// two passes are comparable however the buffer moved between them.
    private func agreedPrefix(_ earlier: [Word], _ current: [Word]) -> [Word] {
        var out: [Word] = []
        for (a, b) in zip(earlier, current) {
            guard a.text == b.text,
                  abs(a.start - b.start) <= configuration.agreementTolerance
            else { break }
            out.append(b)
        }
        return out
    }

    /// Release audio behind the committed text once the tail is long.
    ///
    /// Only ever cuts at or before `committedEnd` - uncommitted audio is still
    /// being argued about - and at the quietest 20 ms it can find there: the
    /// model is sensitive to crops that begin mid-word (see Pipeline's
    /// boundary search), so the next pass's window should start in a pause.
    private func release(passed samples: [Float], from start: TimeInterval) {
        let duration = Double(samples.count) / modelRate
        guard duration > configuration.commitAfter, committedEnd > start else { return }
        let cut = Swift.min(
            quietestPoint(in: samples, near: committedEnd - start) + start,
            committedEnd)
        let drop = Swift.min(Int((cut - start) * modelRate), buffer.count)
        guard drop > 0 else { return }
        // Rebuilt rather than `removeFirst` for the same reason the pipeline's
        // release is: trimming in place keeps the old capacity forever.
        buffer = Array(buffer[drop...])
        bufferStart += Double(drop) / modelRate
    }

    /// The quietest 20 ms frame within a second either side of `at` (seconds
    /// relative to `samples`), as a time relative to the same origin.
    private func quietestPoint(in samples: [Float], near at: TimeInterval) -> TimeInterval {
        let frame = Swift.max(1, Int(0.02 * modelRate))
        let first = Swift.max(0, Int((at - 1) * modelRate))
        let last = Swift.min(samples.count - frame, Int((at + 1) * modelRate))
        guard last > first else { return at }
        var bestAt = Int(at * modelRate)
        var best = Float.greatestFiniteMagnitude
        var index = first
        while index + frame <= last {
            var sum: Float = 0
            for i in index..<(index + frame) { sum += samples[i] * samples[i] }
            if sum < best { best = sum; bestAt = index + frame / 2 }
            index += frame
        }
        return Double(bestAt) / modelRate
    }

    deinit {
        continuation.finish()
    }
}
#endif
