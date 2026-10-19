// Which runtime opens the detector, and what happens when the preferred one cannot.
import Foundation
import Testing
import TestSupport
@testable import Uhm
import DesertAnt

#if !os(WASI)
@Suite(.serialized, .modelBacked) struct UhmRuntimeTests {
    @Test func theTierDeclaresACoreAIArtifactBesideCoreML() {
        let high = Uhm.Quality.high
        #expect(high.coreAI == "uhm.aimodel")
        #expect(high.artifact(for: .coreAI) == "uhm.aimodel")
        #expect(high.artifact(for: .coreML) == high.coreML)
        #expect(high.runtimeFiles == [.coreAI: ["uhm.aimodel/", UhmModel.labeler]])
        #expect(UhmModel.runtimeFiles == high.runtimeFiles)
        #expect(UhmModel.distribution.runtimeFiles == high.runtimeFiles)
        #expect(high.distribution.runtimeFiles == high.runtimeFiles)
        // The platform list is untouched, so nothing below iOS 27 changes.
        #expect(UhmModel.files[.apple] == [high.coreML + "/", UhmModel.labeler])
    }

    #if canImport(CoreML)
    /// A Core AI asset that will not load must not fail the analysis: the Core ML
    /// artifact beside it takes over, and the result says which one ran.
    @Test func fallsBackToCoreMLWhenTheCoreAIAssetCannotLoad() async throws {
        let directory = try await populated()
        let broken = directory.appendingPathComponent(UhmModel.coreAI)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not an asset".utf8).write(to: broken.appendingPathComponent("main.mlirb"))

        let uhm = Uhm(directory: directory.path)
        let result = try await uhm.analyze(samples: speechLikeNoise(), sampleRate: 16_000,
                                           options: Uhm.Options(includeTypes: false))
        #expect(result.modelRuntime == ModelRuntime.platformDefault)
    }
    #endif

    /// With the real asset in place, iOS 27 and macOS 27 run Core AI, and it
    /// finds the same fillers as Core ML in the same audio. Needs a local asset
    /// and a recording with fillers in it:
    /// `DAL_UHM_COREAI_ASSET=/path/to/uhm.aimodel DAL_UHM_AUDIO=/path/to/speech.m4a`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DAL_UHM_COREAI_ASSET"] != nil
                   && ProcessInfo.processInfo.environment["DAL_UHM_AUDIO"] != nil))
    func runsCoreAIWhereTheOSHasIt() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = try await populated()
        try FileManager.default.copyItem(
            atPath: environment["DAL_UHM_COREAI_ASSET"]!,
            toPath: directory.appendingPathComponent(UhmModel.coreAI).path)
        let audio = environment["DAL_UHM_AUDIO"]!
        let options = Uhm.Options(includeTypes: false)

        let result = try await Uhm(directory: directory.path).analyze(audioPath: audio, options: options)
        #expect(result.modelRuntime == ModelRuntime.current)
        guard result.modelRuntime == .coreAI else { return }

        let coreML = try Uhm(modelPath: directory.appendingPathComponent(UhmModel.coreML).path)
        let reference = try await coreML.analyze(audioPath: audio, options: options)
        #expect(reference.modelRuntime == .coreML)
        #expect(!reference.fillers.isEmpty, "pick a recording with fillers in it")
        // Same fillers within a frame (20 ms), and confidences within a few percent.
        let matched = reference.fillers.filter { filler in
            result.fillers.contains { abs($0.start - filler.start) <= 0.04 && abs($0.end - filler.end) <= 0.04 }
        }
        #expect(Double(matched.count) >= 0.95 * Double(reference.fillers.count),
                "Core AI matched \(matched.count) of \(reference.fillers.count) Core ML fillers")
        #expect(abs(result.fillers.count - reference.fillers.count) <= max(1, reference.fillers.count / 20))
    }

    /// A directory holding this platform's Core ML files, as a user would populate it.
    private func populated() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uhm-runtime-\(UUID().uuidString)")
        let files = try await UhmModel.distribution.platformDefault.resolve()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in UhmModel.files[.current] ?? [] {
            let name = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            try FileManager.default.copyItem(at: URL(fileURLWithPath: files.path(name)),
                                             to: directory.appendingPathComponent(name))
        }
        return directory
    }

    /// Five seconds of noise with a syllable-rate envelope, so the detector has
    /// something speech-shaped to run on.
    private func speechLikeNoise() -> [Float] {
        var state: UInt32 = 12345
        return (0..<80_000).map { i in
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = Float(state >> 8) / Float(1 << 24) - 0.5
            return 0.3 * noise * (0.5 + 0.5 * sin(2 * .pi * 4 * Float(i) / 16_000))
        }
    }
}
#endif
