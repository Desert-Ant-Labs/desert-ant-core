// Which runtime opens the model, and what happens when the preferred one cannot.
import Foundation
import Testing
import TestSupport
@testable import Clear
import DesertAnt

#if !os(WASI)
@Suite(.serialized, .modelBacked) struct ClearRuntimeTests {
    @Test func theVariantDeclaresACoreAIArtifactBesideCoreML() {
        let studio = ModelVariant.clearStudio
        #expect(studio.coreAI == "clear-studio.aimodel")
        #expect(studio.artifact(for: .coreAI) == "clear-studio.aimodel")
        #expect(studio.artifact(for: .coreML) == studio.coreML)
        #expect(studio.runtimeFiles == [.coreAI: ["clear-studio.aimodel/"]])
        #expect(ClearModel.runtimeFiles == studio.runtimeFiles)
        #expect(ClearModel.distribution.runtimeFiles == studio.runtimeFiles)
        // The platform list is untouched, so nothing below iOS 27 changes.
        #expect(ClearModel.files[.apple] == [studio.coreML + "/"])
    }

    #if canImport(CoreML)
    /// A Core AI asset that will not load must not fail the enhance: the Core ML
    /// artifact beside it takes over, and the result says which one ran.
    @Test func fallsBackToCoreMLWhenTheCoreAIAssetCannotLoad() async throws {
        let directory = try await populated()
        let broken = directory.appendingPathComponent(ClearModel.coreAI)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not an asset".utf8).write(to: broken.appendingPathComponent("main.mlirb"))

        let clear = Clear(directory: directory.path)
        #expect(clear.isDownloaded())
        let result = try await clear.enhance(samples: noisyTone(), sampleRate: 48_000)
        #expect(result.modelRuntime == ModelRuntime.platformDefault)
        #expect(result.modelVariant == .clearStudio)
    }
    #endif

    /// With the real asset in place, iOS 27 and macOS 27 run Core AI, and its
    /// output agrees with Core ML's on the same audio. Needs a local asset:
    /// `DAL_CLEAR_COREAI_ASSET=/path/to/clear-studio.aimodel`.
    /// Not a plain tone: Clear suppresses it to residual, where Core ML's 6-bit
    /// weights alone put the two 18 dB apart.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DAL_CLEAR_COREAI_ASSET"] != nil))
    func runsCoreAIWhereTheOSHasIt() async throws {
        let asset = ProcessInfo.processInfo.environment["DAL_CLEAR_COREAI_ASSET"]!
        let directory = try await populated()
        try FileManager.default.copyItem(
            atPath: asset, toPath: directory.appendingPathComponent(ClearModel.coreAI).path)

        let input = ParityFixture.input()
        let result = try await Clear(directory: directory.path).enhance(samples: input, sampleRate: 48_000)
        #expect(result.modelRuntime == ModelRuntime.current)
        guard result.modelRuntime == .coreAI else { return }

        let files = try await ModelFixture.files(ClearModel.self)
        let coreML = try Clear(modelPath: files.path(ClearModel.artifact))
        let reference = try await coreML.enhance(samples: input, sampleRate: 48_000)
        #expect(reference.modelRuntime == .coreML)
        let snr = snrDB(reference: reference.samples, actual: result.samples)
        #expect(snr > 20, "Core AI output is \(snr) dB from Core ML's")
    }

    /// Concurrent runs on one Core AI model can return all zeros. 40 s fills
    /// four batches at once, and the pause before each call is when it happens.
    /// Needs a local asset: `DAL_CLEAR_COREAI_ASSET=/path/to/clear-studio.aimodel`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DAL_CLEAR_COREAI_ASSET"] != nil))
    func coreAIRunsInParallelWithoutSilence() async throws {
        let asset = ProcessInfo.processInfo.environment["DAL_CLEAR_COREAI_ASSET"]!
        let directory = try await populated()
        try FileManager.default.copyItem(
            atPath: asset, toPath: directory.appendingPathComponent(ClearModel.coreAI).path)
        let clear = Clear(directory: directory.path)
        let input = noisyTone(seconds: 40)
        let options = Clear.Options(mastering: .bypass)

        for call in 0..<10 {
            try await Task.sleep(for: .milliseconds(300))
            let result = try await clear.enhance(samples: input, sampleRate: 48_000, options: options)
            guard result.modelRuntime == .coreAI else { return }
            // The model's first frames are zero by construction, so skip a second.
            var run = 0, longest = 0
            for sample in result.samples.dropFirst(48_000) {
                run = sample == 0 ? run + 1 : 0
                longest = max(longest, run)
            }
            #expect(longest < 12_000, "call \(call) has \(Double(longest) / 48_000) s of digital silence")
        }
    }

    private func populated() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clear-runtime-\(UUID().uuidString)")
        try await ModelFixture.populate(ClearModel.self, into: directory)
        return directory
    }

    private func noisyTone(seconds: Double = 3) -> [Float] {
        var state: UInt32 = 12345
        return (0..<Int(48_000 * seconds)).map { i in
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = Float(state >> 8) / Float(1 << 24) - 0.5
            return 0.3 * sin(2 * .pi * 220 * Float(i) / 48_000) + 0.05 * noise
        }
    }

    private func snrDB(reference: [Float], actual: [Float]) -> Double {
        var signal = 0.0, noise = 0.0
        for (r, a) in zip(reference, actual) {
            signal += Double(r) * Double(r)
            noise += Double(r - a) * Double(r - a)
        }
        return noise == 0 ? .infinity : 10 * log10(signal / noise)
    }
}
#endif
