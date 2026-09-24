#if canImport(COnnxRuntime) && !canImport(CoreML)
import AudioIO
import Foundation
import Testing
@testable import Voz

/// Voz end to end on the ONNX engine, against real speech.
///
/// Opt-in, because the bundle is 1.2 GB and is sideloaded rather than fetched:
/// point `VOZ_ONNX_MODEL_DIR` at a directory holding mel.onnx, encoder.onnx,
/// decoder.onnx, embedding.f16, meta.json and vocab.json, and
/// `VOZ_ONNX_SAMPLE_WAV` at a recording. Without them the suite skips rather
/// than fails, so a normal run on a machine with no bundle stays green.
///
/// What this actually proves is the whole path: the portable WAV decoder, the
/// windowing, the mel and encoder calls, the lane-batched decode with the
/// host-side argmax, and the splice - all of it over DirectML.
struct OnnxEngineTests {
    private static var modelDirectory: URL? {
        ProcessInfo.processInfo.environment["VOZ_ONNX_MODEL_DIR"]
            .map { URL(fileURLWithPath: $0) }
    }

    private static var sampleWAV: URL? {
        ProcessInfo.processInfo.environment["VOZ_ONNX_SAMPLE_WAV"]
            .map { URL(fileURLWithPath: $0) }
    }

    private func samples(_ url: URL) throws -> (audio: [Float], seconds: Double) {
        let pcm = try WAV.decode([UInt8](try Data(contentsOf: url)))
        // Voz wants mono at the model's rate; the fixture is already 16 kHz mono,
        // and a mixdown here would hide it if that ever stopped being true.
        #expect(pcm.channels == 1, "fixture should be mono")
        return (pcm.samples, Double(pcm.samples.count) / pcm.sampleRate)
    }

    @Test func transcribesRealSpeech() async throws {
        guard let directory = Self.modelDirectory, let wav = Self.sampleWAV else {
            withKnownIssue("set VOZ_ONNX_MODEL_DIR and VOZ_ONNX_SAMPLE_WAV to run") {
                Issue.record("skipped")
            }
            return
        }
        let voz = try Voz(modelDirectory: directory)
        let (audio, seconds) = try samples(wav)
        let result = try await voz.transcribe(samples: audio)

        print("""

            ONNX engine, \(String(format: "%.2f", seconds)) s of audio
              transcript      \(result.text)
              words           \(result.words.count)
              processing      \(String(format: "%.3f", result.processingTime)) s
              RTFx            \(String(format: "%.1f", result.realtimeFactor))
            """)

        #expect(!result.text.isEmpty)
        #expect(result.words.count > 10)
        #expect(result.realtimeFactor > 1)
        // Word times must be ordered and inside the audio, which is the cheapest
        // check that the decode's frame bookkeeping survived the port.
        var previous = -1.0
        for word in result.words {
            #expect(word.start >= previous)
            #expect(word.start <= seconds)
            previous = word.start
        }
    }

    /// The GPU and CPU providers must agree. A GPU path that is fast and wrong
    /// is worse than no GPU path, and float16 on a GPU is exactly where that
    /// would show up.
    @Test func gpuAgreesWithCPU() async throws {
        guard let directory = Self.modelDirectory, let wav = Self.sampleWAV else {
            withKnownIssue("set VOZ_ONNX_MODEL_DIR and VOZ_ONNX_SAMPLE_WAV to run") {
                Issue.record("skipped")
            }
            return
        }
        let (audio, _) = try samples(wav)
        let onGPU = try await Voz(modelDirectory: directory, useGPU: true)
            .transcribe(samples: audio)
        let onCPU = try await Voz(modelDirectory: directory, useGPU: false)
            .transcribe(samples: audio)
        print("\n  GPU \(String(format: "%.1f", onGPU.realtimeFactor))x"
              + "   CPU \(String(format: "%.1f", onCPU.realtimeFactor))x")
        #expect(onGPU.text == onCPU.text)
    }
}
#endif
