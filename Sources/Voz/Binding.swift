// Voz's side of the cross-language binding: construction, plus the payload
// schemas that are genuinely model-specific (what a run takes, and what a
// result looks like). The generic handle lifecycle and the exported symbols
// live in NativeBindings and VozNative, so this file is only the model's
// adapter.
//
// The Swift SDK's public face is the `Voz` actor, whose init resolves and
// loads the model. A host binding must construct lazily (no work until the
// first run), so the bound object is a thin shell that creates the actor on
// first use rather than the actor itself.

#if !os(WASI) && (canImport(CoreML) || canImport(CLiteRt))
import DesertAnt
import Foundation

/// One bound Voz instance: lazy resolve-and-load around the `Voz` actor.
public final class VozBound: BoundModel, @unchecked Sendable {
    private let directory: String?
    private let cacheRoot: String?
    /// Created on the first run and reused; the actor serialises transcription.
    private var voz: Voz?

    init(cacheRoot: String?, directory: String?) {
        self.cacheRoot = cacheRoot
        self.directory = directory
    }

    public func isDownloaded() -> Bool {
        VozModel.isAvailable(directory: directory, cacheRoot: cacheRoot)
    }

    public func download(progress: @Sendable @escaping (Double) -> Void) async throws {
        try await Voz.download(directory: directory, cacheRoot: cacheRoot) {
            progress($0.fraction)
        }
    }

    /// Input payload: `f32Array` samples (mono), then `f64 sampleRate`. Audio
    /// at any rate is accepted and resampled; the model's rate avoids the
    /// conversion. Mono because that is what the recogniser hears; a host with
    /// stereo downmixes before it calls.
    ///
    /// Options payload: empty (all defaults). Reserved: every future group is
    /// appended, never reordered, so a host built against this schema keeps
    /// reading the prefix it knows.
    ///
    /// Result payload: `string text`, then `u32 count` and that many
    /// `(string word, f64 start, f64 end)` in transcript order (seconds from
    /// the start of the audio), then `f64 duration` (seconds transcribed).
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        let samples = input.f32Array()
        let sampleRate = input.f64()
        guard !samples.isEmpty, sampleRate > 0 else { return nil }

        do {
            let voz = try await instance()
            let result = try await voz.transcribe(samples: samples, sampleRate: sampleRate)
            var w = FFIWriter()
            w.string(result.text)
            w.u32(result.words.count)
            for word in result.words {
                w.string(word.text)
                w.f64(word.start)
                w.f64(word.end)
            }
            w.f64(result.duration)
            return w.bytes
        } catch {
            return nil
        }
    }

    private func instance() async throws -> Voz {
        if let voz { return voz }
        let made = try await Voz(directory: directory, cacheRoot: cacheRoot)
        voz = made
        return made
    }
}

/// How the generic bindings construct Voz.
public enum VozBinding: ModelBinding {
    public static let id = VozModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        VozBound(cacheRoot: cacheRoot, directory: directory)
    }
}
#endif
