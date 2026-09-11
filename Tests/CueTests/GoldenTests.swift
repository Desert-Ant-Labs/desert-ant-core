// The Swift frontend is a hand port of kaldi_native_fbank, and the model folds
// Kaldi CMVN into its first layer, so a frontend that drifts produces confident
// nonsense rather than an error. These vectors come from the Python
// implementation in cue-training (scripts/10_export_swift.py) and are the only
// thing that catches it.

import Foundation
import Testing

@testable import Cue

#if canImport(CoreML)

struct Golden: Decodable {
    struct Clip: Decodable {
        let file: String
        let samples: Int
        let duration: Double
        let frames: Int
        let mels: Int
        let firstFrame: [Float]
        let lastFrame: [Float]
        let frameSums: [Float]
        let probs: [Float]
        let segments: [[Double]]
    }
    struct LCG: Decodable {
        let seed: Int, a: Int, c: Int, modulus: Int, scale: Double, samples: Int
    }
    struct Synthetic: Decodable {
        let lcg: LCG
        let frames: Int
        let firstFrame: [Float]
        let lastFrame: [Float]
        let frameSums: [Float]
    }
    /// A copy of the frontend half of `cue_meta.json`, so the frontend tests
    /// can run without the downloaded model.
    let geometry: Frontend.Geometry
    let clips: [Clip]
    let synthetic: Synthetic
}

enum Fixtures {
    static func golden() throws -> Golden {
        let url = try #require(Bundle.module.url(forResource: "cue_golden",
                                                 withExtension: "json"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    /// int16-scale samples straight from the fixture WAV, so the frontend is
    /// tested on exactly the numbers Python saw.
    static func samples(_ name: String) throws -> [Float] {
        let base = (name as NSString).deletingPathExtension
        let url = try #require(Bundle.module.url(forResource: base, withExtension: "wav"))
        let data = try Data(contentsOf: url)
        // Minimal PCM16 WAV reader: walk the chunk list to `data`.
        var offset = 12
        var start = -1, bytes = 0
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = data[(offset + 4)..<(offset + 8)]
                .reversed().reduce(0) { $0 << 8 | Int($1) }
            if id == "data" { start = offset + 8; bytes = size; break }
            offset += 8 + size + (size & 1)
        }
        #expect(start > 0, "no data chunk in \(name)")
        return (0..<(bytes / 2)).map { i in
            let lo = Int16(data[start + i * 2]), hi = Int16(bitPattern: UInt16(data[start + i * 2 + 1]))
            return Float(Int16(bitPattern: UInt16(bitPattern: hi) << 8 | UInt16(bitPattern: lo) & 0xFF))
        }
    }

    static func frontend() throws -> Frontend {
        try Frontend(geometry: try golden().geometry)
    }

    /// A laid-out model directory, or nil.
    ///
    /// The model is downloaded rather than bundled, so the end-to-end vectors
    /// need one to be present. `CUE_MODEL_DIR` points at an export directly
    /// (what `cue-training` writes with `--repo-out`); otherwise the managed
    /// cache is used if something has already fetched it. The frontend tests
    /// deliberately do NOT go through here: the hand-ported filterbank is the
    /// part most likely to drift, so it stays covered with no model at all.
    static func modelDirectory() -> URL? {
        if let path = ProcessInfo.processInfo.environment["CUE_MODEL_DIR"] {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// `CUE_MODEL_DIR` if set, else the managed cache. `hasModel` gates every
    /// caller, so this never reaches the network.
    static func resolvedModelDirectory() async throws -> URL {
        if let directory = modelDirectory() { return directory }
        return URL(fileURLWithPath: try await CueModel.resolve().rootPath)
    }

    static func cue() async throws -> Cue {
        try Cue(modelDirectory: try await resolvedModelDirectory())
    }

    static var hasModel: Bool { modelDirectory() != nil || Cue.isDownloaded() }

    /// The same generator the Python side used, so the synthetic case needs no
    /// binary fixture.
    static func lcg(_ p: Golden.LCG) -> [Float] {
        var s = p.seed
        return (0..<p.samples).map { _ in
            s = (p.a &* s &+ p.c) % p.modulus
            return Float((Double(s) / Double(1 << 30) - 1.0) * p.scale)
        }
    }
}

struct FrontendGoldenTests {
    /// Tolerance is float32 noise: the Python reference computes its FFT in
    /// float64 and Accelerate does not. Measured margin when this was written
    /// is 1.7e-5 on the worst mel bin, so this leaves 100x of room and still
    /// fails on anything structural (`goldenComparisonDetectsDrift`).
    static let tolerance: Float = 2e-3

    @Test func matchesPythonOnSyntheticNoise() throws {
        let g = try Fixtures.golden()
        let frontend = try Fixtures.frontend()
        let (values, frames) = frontend.features(Fixtures.lcg(g.synthetic.lcg))
        #expect(frames == g.synthetic.frames)
        let mels = 80
        for m in 0..<mels {
            #expect(abs(values[m] - g.synthetic.firstFrame[m]) < Self.tolerance)
            #expect(abs(values[(frames - 1) * mels + m] - g.synthetic.lastFrame[m])
                        < Self.tolerance)
        }
        for f in 0..<frames {
            var sum: Float = 0
            for m in 0..<mels { sum += values[f * mels + m] }
            // The sum accumulates 80 bins, so it tolerates 80x one bin's error.
            #expect(abs(sum - g.synthetic.frameSums[f]) < Self.tolerance * Float(mels))
        }
    }

    @Test func matchesPythonOnSpeech() throws {
        let g = try Fixtures.golden()
        let frontend = try Fixtures.frontend()
        for clip in g.clips {
            let samples = try Fixtures.samples(clip.file)
            #expect(samples.count == clip.samples, "\(clip.file) decoded wrong")
            let (values, frames) = frontend.features(samples)
            #expect(frames == clip.frames, "\(clip.file) frame count")
            for m in 0..<clip.mels {
                #expect(abs(values[m] - clip.firstFrame[m]) < Self.tolerance,
                        "\(clip.file) first frame mel \(m)")
                #expect(abs(values[(frames - 1) * clip.mels + m] - clip.lastFrame[m])
                            < Self.tolerance, "\(clip.file) last frame mel \(m)")
            }
            for f in 0..<frames {
                var sum: Float = 0
                for m in 0..<clip.mels { sum += values[f * clip.mels + m] }
                #expect(abs(sum - clip.frameSums[f]) < Self.tolerance * Float(clip.mels),
                        "\(clip.file) frame \(f) checksum")
            }
        }
    }

    @Test func snipEdgesDropsThePartialTail() throws {
        let frontend = try Fixtures.frontend()
        // 400-sample window, 160-sample hop, no padding: 559 samples is one
        // frame plus a partial that Kaldi discards.
        #expect(frontend.frameCount(samples: 399) == 0)
        #expect(frontend.frameCount(samples: 400) == 1)
        #expect(frontend.frameCount(samples: 559) == 1)
        #expect(frontend.frameCount(samples: 560) == 2)
    }
}

@Suite(.enabled(if: Fixtures.hasModel,
                "needs the model: set CUE_MODEL_DIR or run Cue.download()"))
struct EndToEndGoldenTests {
    @Test func probabilitiesMatchPython() async throws {
        let g = try Fixtures.golden()
        let cue = try await Fixtures.cue()
        for clip in g.clips {
            let samples = try Fixtures.samples(clip.file).map { $0 / 32768 }
            let result = try cue.detect(samples: samples)
            #expect(result.probabilities.count == clip.probs.count)
            var worst: Float = 0
            for (a, b) in zip(result.probabilities, clip.probs) {
                worst = max(worst, abs(a - b))
            }
            // fp16 on the Neural Engine against fp16 in Python: the same
            // arithmetic, so this is tight. Measured worst delta is 4.88e-4,
            // which is one fp16 ULP at this magnitude, i.e. the output format
            // rather than the computation.
            #expect(worst < 0.02, "\(clip.file) max prob delta \(worst)")
        }
    }

    /// The segmenter is a port of the upstream post-processor, and the goldens
    /// were produced by running that Python on these clips.
    @Test func segmentsMatchPython() async throws {
        let g = try Fixtures.golden()
        let cue = try await Fixtures.cue()
        for clip in g.clips {
            let samples = try Fixtures.samples(clip.file).map { $0 / 32768 }
            let result = try cue.detect(samples: samples)
            #expect(result.speech.count == clip.segments.count, "\(clip.file) span count")
            for (span, expected) in zip(result.speech, clip.segments) {
                #expect(abs(span.start - expected[0]) < 0.02, "\(clip.file) start")
                #expect(abs(span.end - expected[1]) < 0.02, "\(clip.file) end")
            }
        }
    }
}

#endif
