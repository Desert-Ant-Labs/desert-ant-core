import AudioIO
import DesertAnt
import Foundation

/// Runs the pipeline: resample -> log-mel over the whole recording -> the
/// encoder graph over a piece -> the query graph -> the decision rule -> turns;
/// and, past one piece, the voice graph over the recording -> a voice per
/// lane -> the lanes clustered -> one numbering.
final class Model: @unchecked Sendable {
    /// The sidecar `who_meta.json`; field names are its.
    struct Meta: Decodable {
        struct ModelInfo: Decodable { let id: String; let architecture: String; let dim: Int; let queries: Int }
        struct Audio: Decodable { let sample_rate: Int }
        struct FrontendInfo: Decodable {
            let frame_samples: Int
            let shift_samples: Int
            let n_fft: Int
            let n_mels: Int
            let preemphasis: Float
            let scale: Float
            let log_floor: Float
        }
        struct Frames: Decodable { let step_s: Double; let first_centre_s: Double; let downsample: Int }
        /// One graph: its file, the signature within it when the file holds several (the LiteRT file), its tensor names.
        struct Graph: Decodable { let compiled: String; let signature: String?; let inputs: [String]; let outputs: [String] }
        /// One window length, with the pair of graphs traced for it.
        struct WindowInfo: Decodable {
            let seconds: Double
            /// The window's 10 ms frames, and the 100 ms frames the query graph attends over.
            let frames: Int
            let low: Int
            /// The 10 ms frames each mask output holds, summing to `frames`.
            let chunks: [Int]
            let encoder: Graph
            let queries: Graph
        }
        struct EmbeddingInfo: Decodable { let weights: String; let dim: Int }
        /// The voice graph: the released trunk over its own filterbank, read in windows.
        struct VoiceInfo: Decodable {
            let compiled: String
            let signature: String?
            let inputs: [String]
            let outputs: [String]
            let mel_frames: Int
            let margin_mel_frames: Int
            let mel_frames_per_column: Int
            let columns_dim: Int
            let frontend: FrontendInfo
            let embedding: EmbeddingInfo
        }
        /// How the lanes of several pieces become the recording's speakers.
        struct JoinInfo: Decodable {
            let cosine: Float
            let min_solo_s: Double
            /// What a lane without a voice becomes: "fold", the speaker of the voiced lane nearest it in time, or "keep", its own.
            let voiceless: String?
        }
        struct DecisionInfo: Decodable { let presence_threshold: Float; let mask_threshold: Float; let rule: Decision.Rule; let pool: Int }
        let schema: Int
        let model: ModelInfo
        let audio: Audio
        let frontend: FrontendInfo
        let frames: Frames
        let windows: [WindowInfo]
        let voice: VoiceInfo?
        let join: JoinInfo?
        let decision: DecisionInfo
    }

    /// A decided lane of one piece: which query, its turns on the recording's clock, and the 10 ms
    /// frames of its piece where it speaks alone.
    struct Lane {
        let piece: Int
        let query: Int
        let turns: [LabelledTurn]
        let solo: [Float]
        let offset: Int
    }

    let meta: Meta
    var sampleRate: Int { frontend.geometry.sampleRate }
    private let frontend: Frontend
    private let decision: Decision
    private let clock: FrameClock
    private let sessions: [String: any InferenceSession]
    /// Shortest window first, as a piece picks the first that holds it.
    private let windows: [Meta.WindowInfo]
    /// The voice path, or nil for an artifact that ships none, whose pieces then keep their own speakers.
    private let voiceFrontend: Frontend?
    private let embedding: Embedding?

    init(assets: ModelAssets) throws {
        let meta = try JSONDecoder().decode(Meta.self, from: Data(assets.metaJSON.utf8))
        guard meta.model.id == WhoModel.id else { throw WhoError.invalidModel("the sidecar describes \(meta.model.id)") }
        guard meta.schema == 2, meta.model.architecture == "eend_m2f" else {
            throw WhoError.invalidModel("the sidecar is schema \(meta.schema) for \(meta.model.architecture)")
        }
        guard !meta.windows.isEmpty else { throw WhoError.invalidModel("the sidecar traces no window") }
        for window in meta.windows {
            guard window.frames == window.low * meta.frames.downsample else {
                throw WhoError.invalidModel("the \(window.seconds) s window is not a whole number of \(meta.frames.downsample)-frame steps")
            }
            guard window.chunks.reduce(0, +) == window.frames, window.chunks.count + 1 == window.queries.inputs.count else {
                throw WhoError.invalidModel("the \(window.seconds) s window's chunks do not cover it")
            }
            for graph in [window.encoder, window.queries] {
                guard assets.sessions[Model.key(graph.compiled, graph.signature)] != nil else { throw WhoError.invalidModel("no session for \(graph.compiled)") }
            }
        }
        self.meta = meta
        windows = meta.windows.sorted { $0.frames < $1.frames }
        frontend = try Frontend(geometry: Model.geometry(meta.frontend, rate: meta.audio.sample_rate), banksTable: assets.melBanks)
        decision = Decision(presenceThreshold: meta.decision.presence_threshold, maskThreshold: meta.decision.mask_threshold,
                            rule: meta.decision.rule, pool: meta.decision.pool)
        clock = FrameClock(step: meta.frames.step_s, firstCentre: meta.frames.first_centre_s)
        if let voice = meta.voice {
            guard meta.join != nil else { throw WhoError.invalidModel("a voice graph without a join") }
            guard voice.mel_frames % voice.mel_frames_per_column == 0, voice.margin_mel_frames % voice.mel_frames_per_column == 0 else {
                throw WhoError.invalidModel("the voice window is not whole columns")
            }
            guard assets.sessions[Model.key(voice.compiled, voice.signature)] != nil else { throw WhoError.invalidModel("no session for \(voice.compiled)") }
            voiceFrontend = try Frontend(geometry: Model.geometry(voice.frontend, rate: meta.audio.sample_rate), banksTable: assets.voiceBanks)
            let layer = try Embedding(sidecar: assets.embedding)
            guard layer.columns == voice.columns_dim, layer.out == voice.embedding.dim else {
                throw WhoError.invalidModel("the embedding sidecar is \(layer.out) x \(2 * layer.columns), the sidecar says \(voice.embedding.dim) x \(2 * voice.columns_dim)")
            }
            embedding = layer
        } else {
            voiceFrontend = nil
            embedding = nil
        }
        sessions = assets.sessions
    }

    /// The session a graph runs on: named by its signature when its file holds several graphs, else by its file.
    private static func key(_ compiled: String, _ signature: String?) -> String {
        signature ?? (String(compiled.split(separator: "/").last ?? "").components(separatedBy: ".").first ?? compiled)
    }

    private static func geometry(_ info: Meta.FrontendInfo, rate: Int) -> Frontend.Geometry {
        Frontend.Geometry(sampleRate: rate, frame: info.frame_samples, shift: info.shift_samples, nFFT: info.n_fft, mels: info.n_mels,
                          preemphasis: info.preemphasis, scale: info.scale, logFloor: info.log_floor)
    }

    /// The longest recording one piece holds, in seconds.
    var maximumSeconds: Double { windows.last!.seconds }

    /// One piece when the recording fits, else pieces end to end, their lanes joined by voice when the
    /// artifact ships a voice graph, each piece's lanes its own when it does not.
    func diarize(samples: [Float], sampleRate: Double) async throws -> Diarization {
        let audio = resampled(samples, from: sampleRate)
        let seconds = Double(audio.count) / Double(frontend.geometry.sampleRate)
        let melFrames = frontend.frames(for: audio.count)
        guard melFrames > 0 else { throw WhoError.invalidAudio("shorter than one frame") }
        let pieces = Pieces.cut(frames: melFrames, window: windows.last!.frames)
        let joins = pieces.count > 1 && voiceFrontend != nil && embedding != nil && meta.voice != nil && meta.join != nil
        let (means, voiceMeans) = await self.means(audio, voice: joins)

        if pieces.count == 1 {
            let (presence, masks, _) = try await graphs(input(audio, piece: pieces[0], means: means), piece: pieces[0])
            let stretches = decision.stretches(presence: Decision.sigmoid(presence), masks: Decision.sigmoid(masks), frames: pieces[0].frames)
            return Diarization(stretches: stretches, clock: clock, duration: seconds)
        }

        // The Neural Engine reads one piece while the CPU computes the next one's features and decides the one
        // before, so neither waits for the other. The lanes still come out in piece order.
        var lanes: [Lane] = []
        var next = input(audio, piece: pieces[0], means: means)
        var read: (index: Int, presence: [Float], masks: [Float])?
        for (index, piece) in pieces.enumerated() {
            let current = next
            async let out = graphs(current, piece: piece)
            next = index + 1 < pieces.count ? input(audio, piece: pieces[index + 1], means: means) : []
            if let read { lanes += self.lanes(of: read.index, piece: pieces[read.index], presence: read.presence, masks: read.masks) }
            let (presence, masks, _) = try await out
            read = (index, presence, masks)
        }
        if let read { lanes += self.lanes(of: read.index, piece: pieces[read.index], presence: read.presence, masks: read.masks) }

        guard joins, let voiceFrontend, let embedding, let voice = meta.voice, let join = meta.join, let voiceMeans else {
            return Diarization(turns: lanes.flatMap(\.turns), duration: seconds)
        }
        let labels = try await joined(lanes, audio: audio, melFrames: melFrames, voiceFrontend: voiceFrontend, voiceMeans: voiceMeans,
                                      embedding: embedding, voice: voice, join: join)
        var turns: [LabelledTurn] = []
        for (lane, label) in zip(lanes, labels) {
            turns += lane.turns.map { LabelledTurn(start: $0.start, end: $0.end, label: label) }
        }
        return Diarization(turns: Linker.joined(turns), duration: seconds)
    }

    /// The model filterbank's means and, for a recording the join will read, the voice filterbank's, from one
    /// spectrum per frame when the two share it.
    private func means(_ audio: [Float], voice: Bool) async -> (model: [Float], voice: [Float]?) {
        guard voice, let voiceFrontend else { return (await Frontend.means([frontend], samples: audio).means[0], nil) }
        if frontend.sharesSpectrum(with: voiceFrontend) {
            let both = await Frontend.means([frontend, voiceFrontend], samples: audio).means
            return (both[0], both[1])
        }
        let model = await Frontend.means([frontend], samples: audio).means[0]
        return (model, await Frontend.means([voiceFrontend], samples: audio).means[0])
    }

    /// One read piece's lanes: each query that speaks, its turns on the recording's clock, and the frames where
    /// it speaks alone.
    private func lanes(of index: Int, piece: Piece, presence: [Float], masks: [Float]) -> [Lane] {
        let probabilities = Decision.sigmoid(masks)
        let stretches = decision.stretches(presence: Decision.sigmoid(presence), masks: probabilities, frames: piece.frames)
        let offset = Double(piece.first) * meta.frames.step_s
        let decided = Array(Set(stretches.map(\.query))).sorted()
        var on = [[Bool]](repeating: [Bool](repeating: false, count: piece.frames), count: decided.count)
        for (row, query) in decided.enumerated() {
            for f in 0..<piece.frames { on[row][f] = probabilities[query * piece.frames + f] > decision.maskThreshold }
        }
        var lanes: [Lane] = []
        for (row, query) in decided.enumerated() {
            var solo = [Float](repeating: 0, count: piece.frames)
            for f in 0..<piece.frames where on[row][f] {
                var alone = true
                for other in on.indices where other != row && on[other][f] { alone = false; break }
                if alone { solo[f] = 1 }
            }
            let turns = stretches.filter { $0.query == query }.map { stretch -> LabelledTurn in
                let (start, end) = clock.bounds(stretch)
                return LabelledTurn(start: start + offset, end: end + offset, label: index * meta.model.queries + query)
            }
            lanes.append(Lane(piece: index, query: query, turns: turns, solo: solo, offset: piece.first))
        }
        return lanes
    }

    /// Every lane's voice, pooled over the columns where it speaks alone, clustered at the join's cut; a
    /// lane with too little solo speech has no voice and a label of its own.
    private func joined(_ lanes: [Lane], audio: [Float], melFrames: Int, voiceFrontend: Frontend, voiceMeans: [Float], embedding: Embedding,
                        voice: Meta.VoiceInfo, join: Meta.JoinInfo) async throws -> [Int] {
        let perColumn = voice.mel_frames_per_column
        let voiceFrames = voiceFrontend.frames(for: audio.count)
        let used = min(voiceFrames, melFrames) / perColumn * perColumn
        let columns = used / perColumn
        let mels = voiceFrontend.geometry.mels
        let minimum = Int((join.min_solo_s / meta.frames.step_s).rounded())
        let masks: [[Bool]?] = lanes.map { lane in
            let frames = Int(lane.solo.reduce(0, +))
            return frames >= minimum ? Voices.columnMask(solo: lane.solo, offset: lane.offset, columns: columns, perColumn: perColumn) : nil
        }
        var pools = masks.map { $0 == nil ? nil : Embedding.Pool(columns: embedding.columns) }
        let width = voice.mel_frames
        // A window whose kept columns hold no lane's solo column adds to no pool, so it is not run.
        let needed = Voices.windows(melFrames: used, width: width, margin: voice.margin_mel_frames, perColumn: perColumn).filter { window in
            let placed = window.placeLow..<(window.placeLow + window.keepHigh - window.keepLow)
            return masks.contains { $0?[placed].contains(true) ?? false }
        }
        func input(_ window: VoiceWindow) -> [Float] {
            var input = [Float](repeating: 0, count: width * mels)
            let available = min(width, used - window.start)
            input.replaceSubrange(0..<(available * mels), with: voiceFrontend.features(audio, frames: window.start..<(window.start + available), means: voiceMeans))
            return input
        }
        func pool(_ window: VoiceWindow, _ out: [Float]) {
            for row in window.keepLow..<window.keepHigh {
                let column = window.placeLow + (row - window.keepLow)
                for g in lanes.indices where masks[g]?[column] == true {
                    pools[g]!.add(out, offset: row * embedding.columns)
                }
            }
        }
        // As with the pieces: the Neural Engine reads one window while the CPU computes the next one's features
        // and pools the one before. The pools still take the windows in order, so their sums are the same.
        if !needed.isEmpty {
            let key = Model.key(voice.compiled, voice.signature)
            var next = input(needed[0])
            var read: (window: VoiceWindow, out: [Float])?
            for (index, window) in needed.enumerated() {
                let current = next
                async let out = run(key, inputs: [voice.inputs[0]: Tensor(float32: current, shape: [1, width, mels])],
                                    outputs: voice.outputs, expected: [(width / perColumn) * embedding.columns])
                next = index + 1 < needed.count ? input(needed[index + 1]) : []
                if let read { pool(read.window, read.out) }
                read = (window, try await out[0])
            }
            if let read { pool(read.window, read.out) }
        }
        var voices: [[Float]] = []
        var voiced: [Int] = []
        for g in lanes.indices {
            if let pool = pools[g], let unit = embedding.embed(pool) {
                voices.append(unit)
                voiced.append(g)
            }
        }
        var labels = [Int](repeating: -1, count: lanes.count)
        let clustered = AverageLinkage.cluster(voices, cosine: join.cosine)
        for (g, label) in zip(voiced, clustered) { labels[g] = label }
        if join.voiceless == "fold", !voiced.isEmpty {
            for g in lanes.indices where labels[g] < 0 {
                labels[g] = labels[Voices.nearest(to: lanes[g].turns, among: voiced.map { lanes[$0].turns }, lanes: voiced)]
            }
            return Voices.firstAppearance(labels)
        }
        var next = (clustered.max() ?? -1) + 1
        for g in lanes.indices where labels[g] < 0 {
            labels[g] = next
            next += 1
        }
        return labels
    }

    /// A recording that fits the longest window, as one piece.
    func logits(_ audio: [Float]) async throws -> (presence: [Float], masks: [Float], queries: [Float], frames: Int) {
        let (means, melFrames) = await Frontend.means([frontend], samples: audio)
        let mean = means[0]
        guard melFrames > 0 else { throw WhoError.invalidAudio("shorter than one frame") }
        guard melFrames <= windows.last!.frames else { throw WhoError.invalidAudio("longer than the \(Int(maximumSeconds)) s one piece holds") }
        let out = try await logits(audio, piece: Piece(first: 0, end: melFrames), means: mean)
        return (out.presence, out.masks, out.queries, melFrames)
    }

    /// One piece through both graphs: the last decoder layer's presence logits
    /// `[queries]`, its mask logits `[queries * piece.frames]`, and the queries
    /// themselves `[queries * dim]`, one vector a speaker. The piece's log-mel is
    /// computed here, against the recording's `means`, so only one piece's is held.
    func logits(_ audio: [Float], piece: Piece, means: [Float]) async throws -> (presence: [Float], masks: [Float], queries: [Float]) {
        guard piece.frames > 0, piece.end <= frontend.frames(for: audio.count) else { throw WhoError.invalidAudio("a piece outside the recording") }
        return try await graphs(input(audio, piece: piece, means: means), piece: piece)
    }

    /// The encoder's input for one piece: its log-mel against the recording's `means`, then its last frame
    /// repeated to fill the window.
    private func input(_ audio: [Float], piece: Piece, means: [Float]) -> [Float] {
        let mels = frontend.geometry.mels
        let window = windows[windowIndex(for: piece.frames)]
        let mel = frontend.features(audio, frames: piece.first..<piece.end, means: means)
        var input = [Float](repeating: 0, count: window.frames * mels)
        input.replaceSubrange(0..<(piece.frames * mels), with: mel)
        let last = Array(mel[((piece.frames - 1) * mels)..<(piece.frames * mels)])
        for frame in piece.frames..<window.frames {
            input.replaceSubrange((frame * mels)..<((frame + 1) * mels), with: last)
        }
        return input
    }

    /// One piece's encoder input through both graphs, as `logits` describes.
    private func graphs(_ input: [Float], piece: Piece) async throws -> (presence: [Float], masks: [Float], queries: [Float]) {
        let mels = frontend.geometry.mels, dim = meta.model.dim, count = meta.model.queries
        let window = windows[windowIndex(for: piece.frames)]

        let encoded = try await run(Model.key(window.encoder.compiled, window.encoder.signature), inputs: [window.encoder.inputs[0]: Tensor(float32: input, shape: [1, window.frames, mels])],
                                    outputs: window.encoder.outputs, expected: [window.low * dim, window.frames * dim])
        var inputs = [window.queries.inputs[0]: Tensor(float32: encoded[0], shape: [1, window.low, dim])]
        var at = 0
        for (index, frames) in window.chunks.enumerated() {
            inputs[window.queries.inputs[index + 1]] = Tensor(float32: Array(encoded[1][(at * dim)..<((at + frames) * dim)]), shape: [1, frames, dim])
            at += frames
        }
        let out = try await run(Model.key(window.queries.compiled, window.queries.signature), inputs: inputs, outputs: window.queries.outputs,
                                expected: [count, count * dim] + window.chunks.map { count * $0 })
        return (out[0], masks(Array(out[2...]), chunks: window.chunks, frames: piece.frames, queries: count), out[1])
    }

    /// The chunks' mask logits as one `[queries * frames]`, the padding dropped.
    private func masks(_ outputs: [[Float]], chunks: [Int], frames: Int, queries: Int) -> [Float] {
        var out = [Float](repeating: 0, count: queries * frames)
        var at = 0
        for (output, chunk) in zip(outputs, chunks) {
            let keep = min(chunk, frames - at)
            if keep <= 0 { break }
            for query in 0..<queries {
                out.replaceSubrange((query * frames + at)..<(query * frames + at + keep), with: output[(query * chunk)..<(query * chunk + keep)])
            }
            at += chunk
        }
        return out
    }

    /// The index of the shortest window that holds a piece.
    private func windowIndex(for frames: Int) -> Int {
        windows.firstIndex { $0.frames >= frames } ?? windows.count - 1
    }

    /// One graph run, its outputs as float32 of the expected lengths.
    private func run(_ name: String, inputs: [String: Tensor], outputs: [String], expected: [Int]) async throws -> [[Float]] {
        let tensors = try await sessions[name]!.run(inputs: inputs, outputs: outputs)
        return try zip(tensors, expected).map { tensor, count in
            guard let values = tensor.float32Values, values.count == count else {
                throw WhoError.predictionFailed("\(name) returned \(tensor.count) values, expected \(count)")
            }
            return values
        }
    }

    /// Resample to the model's rate with `AudioIO`'s linear resampler.
    private func resampled(_ samples: [Float], from rate: Double) -> [Float] {
        let target = Double(frontend.geometry.sampleRate)
        guard rate > 0, abs(rate - target) > 1 else { return samples }
        return Resample.linear(samples, from: rate, to: target)
    }
}
