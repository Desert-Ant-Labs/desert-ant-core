#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(WASILibc)
import WASILibc
#endif
import AudioIO
import DesertAnt

/// Runs the pipeline: resample -> log-mel in Swift -> the detector through the
/// shared `InferenceSession` (Core ML on Apple, LiteRT elsewhere) -> language
/// probabilities averaged across windows.
final class Model: @unchecked Sendable {
    let languages: [String]
    var sampleRate: Int { frontend.geometry.sampleRate }
    private let inputName: String
    private let outputName: String
    private let frontend: Frontend
    private let session: any InferenceSession

    private struct Meta: Decodable {
        struct Audio: Decodable { let sample_rate: Int }
        struct Frontend: Decodable {
            let n_fft: Int
            let hop_length: Int
            let n_mels: Int
            let frames: Int
            let clamp_min: Float
            let floor_below_peak_db: Float
            let affine: Affine
        }
        struct Affine: Decodable { let add: Float; let divide: Float }
        /// What each runtime calls the tensors. Core ML takes the name it was
        /// given at conversion; LiteRT takes its signature's, derived from the
        /// graph. Reading them from the artifact keeps one constant from being
        /// right on one platform and wrong on the other.
        struct IO: Decodable { let input: String; let output: String }
        struct Artifacts: Decodable { let coreml: IO; let litert: IO }
        let audio: Audio
        let frontend: Frontend
        let artifacts: Artifacts
    }

    init(assets: ModelAssets) throws {
        let meta = try JSONDecoder().decode(Meta.self, from: assets.metaJSON)
        languages = try JSONDecoder().decode([String].self, from: assets.languagesJSON)
        guard !languages.isEmpty else { throw EarError.invalidModel("no languages") }

        frontend = try Frontend(
            geometry: Frontend.Geometry(
                sampleRate: meta.audio.sample_rate,
                nFFT: meta.frontend.n_fft,
                hop: meta.frontend.hop_length,
                mels: meta.frontend.n_mels,
                frames: meta.frontend.frames,
                clampMin: meta.frontend.clamp_min,
                floorDecades: meta.frontend.floor_below_peak_db,
                affineAdd: meta.frontend.affine.add,
                affineDivide: meta.frontend.affine.divide),
            filterTable: assets.melFilters)
        let io = ModelPlatform.current == .apple ? meta.artifacts.coreml : meta.artifacts.litert
        inputName = io.input
        outputName = io.output
        session = assets.session
    }

    func identify(samples: [Float], sampleRate: Double, windows: Int) async throws -> Detection {
        let audio = resampled(samples, from: sampleRate)
        let geometry = frontend.geometry
        let offsets = frontend.windowOffsets(audio, count: windows)

        // Probabilities are averaged rather than votes counted. A file is one
        // speaker in one room, so the detector's mistakes on it are unanimous
        // rather than independent; averaging lets several unsure but correct
        // windows outweigh one confident wrong one, which counting cannot.
        var totals = [Double](repeating: 0, count: languages.count)
        for offset in offsets {
            let end = min(offset + geometry.windowSamples, audio.count)
            let features = frontend.features(Array(audio[offset..<end]))
            let logits = try await run(features: features)
            let probabilities = softmax(logits)
            for i in totals.indices { totals[i] += probabilities[i] }
        }

        let scale = 1.0 / Double(offsets.count)
        let candidates = totals.enumerated()
            .map { LanguagePrediction(language: canonicalLanguage(languages[$0.offset]),
                                      probability: $0.element * scale) }
            .sorted { $0.probability > $1.probability }
        return Detection(candidates: Array(candidates.prefix(5)), windows: offsets.count)
    }

    private func run(features: [Float]) async throws -> [Float] {
        let geometry = frontend.geometry
        let out = try await session.run(
            inputs: [inputName: Tensor(float32: features,
                                       shape: [1, geometry.mels, geometry.frames])],
            outputs: [outputName])[0]
        guard let logits = out.float32Values, logits.count == languages.count else {
            throw EarError.predictionFailed
        }
        return logits
    }

    /// Resample to the model's rate. Language identification reads broad
    /// spectral shape, so `AudioIO`'s linear resampler is what this needs; the
    /// transcription path's windowed-sinc would cost more and change nothing.
    private func resampled(_ samples: [Float], from rate: Double) -> [Float] {
        let target = Double(frontend.geometry.sampleRate)
        guard rate > 0, abs(rate - target) > 1 else { return samples }
        return Resample.linear(samples, from: rate, to: target)
    }

    private func softmax(_ logits: [Float]) -> [Double] {
        let peak = logits.max() ?? 0
        let exps = logits.map { exp(Double($0 - peak)) }
        let total = exps.reduce(0, +)
        guard total > 0 else { return Array(repeating: 0, count: logits.count) }
        return exps.map { $0 / total }
    }
}
