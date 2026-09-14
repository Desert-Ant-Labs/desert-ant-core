#if canImport(CoreML)
import CoreML
import Foundation
#endif
import AudioIO
import DesertAnt

#if canImport(CoreML)

public extension Voz {

    /// Live dictation: push audio as it is captured, get text as it is spoken.
    ///
    /// ```swift
    /// let live = try await Voz.Live()
    /// await live.prewarm()                     // at app launch, once
    ///
    /// // on key down
    /// Task {
    ///     for await update in await live.start() {
    ///         field.text = update.text         // the transcript as it stands
    ///     }
    /// }
    /// // from the audio callback, on any thread
    /// live.append(samples)
    ///
    /// // on key up
    /// let result = try await live.finish()
    /// ```
    ///
    /// Each update carries the whole transcript, because it can be *revised*.
    /// Two graphs run over the same audio: the streaming one answers in about
    /// 200 ms, and the offline one re-reads the last few seconds with full
    /// context a moment later and corrects it. ``Update/stable`` is the prefix
    /// that has been through the second pass and will not change, so a client
    /// that wants minimal edits can rewrite only the tail.
    ///
    /// Set ``Options/refine`` to `false` for a single-pass stream, where text
    /// only ever appends.
    ///
    /// One instance is one stream. The models are expensive to load and cheap
    /// to keep, so build this once and call ``start()`` per utterance rather
    /// than constructing it per keystroke.
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *)
    actor Live {

        /// How the two passes are scheduled.
        public struct Options: Sendable {
            /// Re-read recent speech with the offline graph and correct it.
            /// On by default: it is most of the accuracy.
            public var refine: Bool = true
            /// Run the low-latency pass and publish its text as provisional.
            ///
            /// Ignored unless the bundle declares its streaming weights trained.
            /// A converted-but-untrained checkpoint emits almost nothing in that
            /// regime and what it does emit is wrong, so running it would spend
            /// a tenth of the engine putting bad words on screen ahead of good
            /// ones. The model file decides; this only turns it off.
            public var provisional: Bool = true
            /// How much new audio to accumulate between refine passes.
            /// Smaller corrects sooner and costs proportionally more.
            public var refineInterval: TimeInterval = 1.5
            /// How far back each pass re-reads. This is the cost and the
            /// accuracy in one number: the offline graph runs at roughly 46x
            /// real time, so a pass costs about `refineContext / 46` seconds,
            /// and a model given more context is a better second opinion.
            /// Nothing is gained past its 15 s training window.
            public var refineContext: TimeInterval = 15
            /// Speech nearer the end than this is left to the streaming pass.
            /// Refining it would give a different answer on the next pass and
            /// the tail would flicker.
            public var volatileTail: TimeInterval = 0.6
            public init() {}
        }

        /// The transcript as it currently stands.
        public struct Update: Sendable {
            /// The whole transcript so far. Assign it; do not append it.
            public let text: String
            /// The prefix of ``text`` that has been through the second pass and
            /// will not change again. Empty until the first refine lands.
            public let stable: String
            /// Every word so far, timed from the start of the stream.
            public let words: [Word]
            /// Which pass produced this update.
            public let source: Source
            /// Where in the stream the newest text starts.
            public let audioTime: TimeInterval
            /// From the audio this text describes being spoken, to it existing.
            /// The number a dictation user experiences.
            ///
            /// Two terms: the model's own lookahead and chunk wait, which are
            /// fixed by the export, plus the time between the caller handing
            /// over the last sample the chunk needed and this update. The SDK
            /// cannot see the microphone, so the second term starts at
            /// ``append(_:)``; a caller pushing at capture rate makes that the
            /// same instant.
            public let latency: TimeInterval

            public enum Source: Sendable {
                /// The low-latency pass. Provisional.
                case streaming
                /// The offline pass, re-reading with full context.
                case refined
            }
        }

        private let assets: LiveAssets
        private let pipeline: LivePipeline
        private let ring = LiveRing()
        /// One chunk's audio, copied out of the ring so the model never runs
        /// while the capture thread is locked out.
        private var window: [Float] = []

        /// Audio rate the model expects. Input at another rate must be resampled
        /// before ``append(_:)``; see ``append(_:sampleRate:)``.
        public nonisolated let sampleRate: Double

        private var continuation: AsyncStream<Update>.Continuation?
        private var tokens: [Int] = []
        private var frames: [Int] = []
        private var ends: [Int] = []
        private var startedAt: Date?
        private let options: Options
        private let refiner: LiveRefiner?
        /// One refine window, reused so a pass does not allocate.
        private var refineScratch: [Float] = []
        private var refinedAt: TimeInterval = 0
        private var running = false
        private var draining = false
        /// Wall clock actually spent in the encoder and decoder, which is not
        /// the session's duration: a live session is mostly waiting for audio.
        private var computeSeconds: TimeInterval = 0
        /// Whether the low-latency pass runs. The bundle has the final say.
        private let streaming: Bool

        // MARK: - Creation

        /// Load the model, downloading it first if needed.
        public init(
            directory: String? = nil,
            cacheRoot: String? = nil,
            options: Options = Options(),
            progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
        ) async throws {
            guard VozModel.supports(.current) else { throw VozError.unsupportedPlatform }
            let stored = try await VozModel.resolve(directory: directory, cacheRoot: cacheRoot,
                                                    progress: progress)
            try self.init(modelDirectory: URL(fileURLWithPath: stored.rootPath),
                          options: options)
        }

        /// Load from a directory of model files you manage yourself.
        public init(modelDirectory: URL,
                    computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
                    options: Options = Options()) throws {
            // Bound to a local first: `&&` takes its right side as a
            // nonisolated autoclosure, which cannot read an actor's stored
            // property during init.
            let loaded = try LiveAssets(directory: modelDirectory,
                                        computeUnits: computeUnits)
            assets = loaded
            pipeline = try LivePipeline(assets: loaded)
            sampleRate = Double(loaded.configuration.sampleRate)
            self.options = options
            streaming = options.provisional && loaded.live.streamingUsable
            if options.refine {
                // The offline functions of the same two files. Core ML maps the
                // weights from disk, so loading the second function shares the
                // pages rather than doubling resident memory.
                let offline = try Assets(directory: modelDirectory,
                                         computeUnits: computeUnits)
                let window = Double(offline.configuration.nSamples)
                    / Double(offline.configuration.sampleRate)
                refiner = try LiveRefiner(
                    assets: offline,
                    windowSeconds: Swift.min(options.refineContext, window),
                    volatileTail: options.volatileTail)
            } else {
                refiner = nil
            }
        }

        // MARK: - Timing contract

        /// Delay from a sample being captured to the text describing it, before
        /// any compute. The floor this build can reach.
        ///
        /// Two terms: the audio the frontend needs from *after* a frame, and the
        /// chunk the frame has to wait out. Both are fixed by the export.
        public var algorithmicLatency: TimeInterval {
            (assets.live.lookaheadMs / 1000)
                + Double(assets.live.chunkFrames - 1) * assets.live.frameSeconds
        }

        /// Audio per encoder dispatch. The latency dial the export was built with.
        public var chunkDuration: TimeInterval { assets.live.chunkSeconds }

        // MARK: - Warmup

        /// Run the graph on silence so the first real chunk is not the slow one.
        ///
        /// Three separate costs hide behind a first prediction, and this pays all
        /// of them off the critical path:
        ///
        /// - Core ML specializes the Neural Engine program on first use.
        /// - Warmup is about three calls: the first is ~3.6x steady, the second
        ///   ~2.1x, the third within 13%.
        /// - The SoC clocks down when idle, and a streaming workload is idle by
        ///   construction. Measured on an M1: the same chunk takes 45.9 ms on an
        ///   otherwise idle machine against 23.4 ms with the package busy, so a
        ///   cold engine is worth about 2x on the first chunk.
        ///
        /// Cheap enough to call on key-down as well as at launch: a chunk needs
        /// a few hundred milliseconds of audio before it can run at all, and a
        /// human takes about that long to start talking after pressing a key, so
        /// this fits in a gap that would otherwise be idle. ``start()`` does it
        /// for you unless you pass `prewarm: false`.
        @discardableResult
        public func prewarm(cycles: Int = 3) -> TimeInterval {
            let began = Date()
            guard streaming else { return 0 }
            let silence = [Float](repeating: 0, count: pipeline.windowSamples)
            silence.withUnsafeBufferPointer { buffer in
                for _ in 0..<Swift.max(1, cycles) {
                    var t: [Int] = [], f: [Int] = [], e: [Int] = []
                    try? pipeline.process(ring: buffer, ringOrigin: pipeline.firstSampleNeeded,
                                          tokens: &t, frames: &f, ends: &e)
                }
            }
            // Warming mutates the caches and the running normalizer, so the
            // stream has to start from nothing again. Skipping this leaves the
            // first real chunk attending over fabricated silence.
            pipeline.reset()
            return Date().timeIntervalSince(began)
        }

        // MARK: - A session

        /// Begin an utterance. The stream yields text as it is recognised and
        /// finishes when ``finish()`` is called.
        public func start(prewarm warm: Bool = true) -> AsyncStream<Update> {
            continuation?.finish()
            if warm { prewarm(cycles: 1) }
            pipeline.reset()
            ring.reset()
            tokens.removeAll(keepingCapacity: true)
            frames.removeAll(keepingCapacity: true)
            ends.removeAll(keepingCapacity: true)
            refiner?.reset()
            refinedAt = 0
            computeSeconds = 0
            if refiner != nil { ring.retain(upTo: Self.refineCeilingSamples) }
            running = true
            startedAt = Date()
            let (stream, continuation) = AsyncStream<Update>.makeStream(
                bufferingPolicy: .unbounded)
            self.continuation = continuation
            return stream
        }

        /// Push captured samples. Safe to call from an audio render callback:
        /// it takes an uncontended lock and returns, and never awaits.
        public nonisolated func append(_ samples: [Float]) {
            // Synchronous: the ring keeps both the chunk window and the
            // utterance the second pass re-reads, under one lock, so a caller
            // that appends everything and calls `finish()` on the next line
            // cannot outrun its own audio.
            ring.append(samples)
            Task { await self.drain() }
        }

        /// Audio the second pass will hold at most. Ten minutes is far past any
        /// dictation turn and is 38 MB of `Float`; a session left open forever
        /// stops being refined rather than growing without bound.
        private static let refineCeilingSamples = 16_000 * 600
        /// Soonest a first pass runs. Below this there is not enough audio for
        /// the frontend's own lookahead to be covered.
        private static let firstPassInterval: TimeInterval = 0.3

        /// Push samples captured at another rate.
        ///
        /// Resampling here rather than inside the recognition task on purpose:
        /// it keeps the conversion on the caller's thread, where a dictation app
        /// already has the buffer hot, instead of adding it to the chunk's
        /// critical path.
        public nonisolated func append(_ samples: [Float], sampleRate rate: Double) {
            guard rate != sampleRate else { return append(samples) }
            append(Resample.linear(samples, from: rate, to: sampleRate))
        }

        /// Stop the stream, flush the last partial chunk, and return everything.
        ///
        /// The flush pads with silence because the model needs a whole window,
        /// and the tail of an utterance is the part a dictation user is most
        /// likely to be watching for.
        public func finish() throws -> Voz.Result {
            guard running else { throw VozError.invalidAudio("no session is running") }
            let captured = ring.streamLength
            let needed = pipeline.samplesNeeded - captured
            if needed > 0 { ring.appendSilence(needed) }
            ring.close()
            try step()

            // One last full-context pass over the tail. This is the half of the
            // transcript the user is most likely to be looking at, and until now
            // it has only ever been seen by the streaming graph.
            if let refiner {
                let began = Date()
                try refiner.refine(ring: ring, scratch: &refineScratch,
                                   through: Double(ring.retainedCount) / sampleRate)
                computeSeconds += Date().timeIntervalSince(began)
                publish(source: .refined, from: tokens.count, ready: 0, delay: 0)
            }
            running = false
            continuation?.finish()
            continuation = nil

            let duration = Double(captured) / sampleRate
            let words = compose().words
            let bounded = words.map {
                $0.end <= duration ? $0
                    : Word(text: $0.text, start: Swift.min($0.start, duration), end: duration)
            }
            return Voz.Result(
                text: render(bounded),
                words: bounded,
                duration: duration,
                // Compute, not session wall clock. A live session lasts as long
                // as the speech does by construction, so reporting elapsed time
                // here would make `realtimeFactor` exactly 1.0 for every
                // recording and say nothing about the machine.
                processingTime: computeSeconds)
        }

        /// Abandon the session without transcribing the rest.
        public func cancel() {
            running = false
            continuation?.finish()
            continuation = nil
            ring.reset()
            pipeline.reset()
            refiner?.reset()
            refinedAt = 0
        }

        // MARK: - The loop

        private func drain() {
            guard running, !draining else { return }
            draining = true
            defer { draining = false }
            try? step()
        }

        /// Run every chunk the ring can now support.
        private func step() throws {
            while running, ring.streamLength >= pipeline.samplesNeeded {
                let firstToken = tokens.count
                let hadWords = !tokens.isEmpty
                // Stream position of the last sample this chunk needed, and the
                // wall clock at which the caller handed it over. The first is
                // the algorithmic half of latency, the second the measured half.
                let ready = Double(pipeline.samplesNeeded) / sampleRate
                let arrived = ring.lastAppendAt
                let began = Date()
                if streaming {
                    let origin = pipeline.firstSampleNeeded
                    ring.copyWindow(from: origin, count: pipeline.windowSamples,
                                    into: &window)
                    try window.withUnsafeBufferPointer { span in
                        try pipeline.process(ring: span, ringOrigin: origin,
                                             tokens: &tokens, frames: &frames, ends: &ends)
                    }
                } else {
                    // Keep the chunk clock running: it is what paces the second
                    // pass and what `firstSampleNeeded` is measured against.
                    pipeline.skip()
                }
                let finished = Date()
                computeSeconds += finished.timeIntervalSince(began)
                ring.release(before: pipeline.firstSampleNeeded)
                _ = hadWords
                if tokens.count > firstToken {
                    publish(source: .streaming, from: firstToken, ready: ready,
                            delay: finished.timeIntervalSince(arrived))
                }
                try refineIfDue(ready: ready, arrived: arrived)
            }
        }

        /// Run a second pass once enough new audio has accumulated.
        ///
        /// Driven by audio arrived rather than by a timer, so a stream that is
        /// paused or fed faster than real time behaves the same way, and a
        /// benchmark measures the same work a microphone would cause.
        private func refineIfDue(ready: TimeInterval, arrived: Date) throws {
            guard let refiner else { return }
            let available = Double(ring.retainedCount) / sampleRate
            let interval = options.refineInterval
            var advanced = false
            let began = Date()

            // Passes land on a fixed grid of audio time, never on "whenever
            // enough arrived". Those are not the same schedule: a caller pushing
            // a file in one call and a microphone pushing 10 ms buffers would
            // otherwise run different numbers of passes at different endpoints,
            // and since each pass is spliced into the last, that changes the
            // transcript. Measured before this was fixed, the same audio scored
            // 3.96% streamed and 14.19% pushed in bulk. A grid makes the two
            // produce the same passes and therefore the same text.
            //
            // The grid is finer over the first interval. A pass reads only what
            // exists, so those early ones are over a fraction of a second and
            // cost a few milliseconds each, and they are the difference between
            // the first word landing at 1.0 s and at 1.7 s. Still a pure
            // function of audio time, so it stays deterministic.
            while true {
                let settled = refiner.refinedThrough
                let step = settled < interval ? Self.firstPassInterval : interval
                let next = (floor(settled / step) + 1) * step
                guard next <= available else { break }
                try refiner.refine(ring: ring, scratch: &refineScratch, through: next)
                advanced = true
                // Guard against a pass that cannot advance the frontier, which
                // would spin here rather than return.
                if refiner.refinedThrough <= settled { break }
            }
            let finished = Date()
            computeSeconds += finished.timeIntervalSince(began)
            refinedAt = available
            guard advanced else { return }
            publish(source: .refined, from: tokens.count, ready: ready,
                    delay: finished.timeIntervalSince(arrived))
        }

        /// Words from the streaming pass that the refiner has not reached.
        private func streamingTail() -> [Word] {
            let all = timedWords(tokens: tokens, frames: frames, ends: ends,
                                 vocabulary: assets.vocabulary,
                                 secondsPerFrame: assets.live.frameSeconds,
                                 timeOffset: 0)
            guard let refiner else { return all }
            return all.filter { $0.start >= refiner.refinedThrough }
        }

        /// The transcript as it stands: refined behind, streaming at the tail.
        private func compose() -> (words: [Word], stable: [Word]) {
            guard let refiner else {
                let all = streamingTail()
                return (all, [])
            }
            let (stable, volatile) = refiner.split()
            return (stable + volatile + streamingTail(), stable)
        }

        private func publish(source: Update.Source, from index: Int,
                             ready: TimeInterval, delay: TimeInterval) {
            guard let continuation else { return }
            let (words, stable) = compose()
            guard !words.isEmpty else { return }
            let audioTime = index < frames.count
                ? Double(frames[index]) * assets.live.frameSeconds
                : words.last?.start ?? 0
            continuation.yield(Update(
                text: render(words),
                stable: render(stable),
                words: words,
                source: source,
                audioTime: audioTime,
                latency: Swift.max(0, ready - audioTime) + Swift.max(0, delay)))
        }

        private func render(_ words: [Word]) -> String {
            words.map(\.text).joined(separator: " ")
        }
    }
}

#endif
