// Who's side of the cross-language binding: construction, plus the payload
// schemas that are genuinely model-specific (what a run takes, and what a
// result looks like). The generic handle lifecycle and the exported symbols
// live in NativeBindings and WhoNative, so this file is only the model's
// adapter.
//
// The Swift SDK's public face is the `Who` class, whose first use resolves and
// loads the model. A host binding must construct lazily (no work until the
// first run), so the bound object is a thin shell around it.

#if canImport(CoreML) || canImport(CLiteRt) || os(WASI)
import DesertAnt
import Foundation

/// One bound Who instance: lazy resolve-and-load around `Who`.
public final class WhoBound: BoundModel, @unchecked Sendable {
    private let directory: String?
    private let cacheRoot: String?
    /// Created on the first use and reused; the model serializes its own runs.
    private var who: Who?

    init(cacheRoot: String?, directory: String?) {
        self.cacheRoot = cacheRoot
        self.directory = directory
    }

    /// A bound instance around a model built from supplied assets, for a host that resolved the files itself.
    @_spi(WhoBindings)
    public init(_ who: Who) {
        cacheRoot = nil
        directory = nil
        self.who = who
    }

    public func isDownloaded() -> Bool {
        Who.isDownloaded(directory: directory, cacheRoot: cacheRoot)
    }

    public func download(progress: @Sendable @escaping (Double) -> Void) async throws {
        try await instance().download(progress: progress)
    }

    /// Input payload: `f32Array` samples (mono), then `f64 sampleRate`. Audio
    /// at any rate is accepted and resampled; the model's rate avoids the
    /// conversion. Mono because that is what the model hears; a host with
    /// stereo downmixes before it calls.
    ///
    /// Options payload: empty (all defaults). Reserved: every future group is
    /// appended, never reordered, so a host built against this schema keeps
    /// reading the prefix it knows.
    ///
    /// Result payload: `u32 speakerCount`, then `u32 count` and that many
    /// `(u32 speaker, f64 start, f64 end)` by start time (seconds from the
    /// start of the audio; speakers numbered from 0 in order of first
    /// appearance; turns of different speakers may overlap), then `f64
    /// duration` (seconds diarized).
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        let samples = input.f32Array()
        let sampleRate = input.f64()
        guard !samples.isEmpty, sampleRate > 0 else { return nil }

        do {
            let who = try instance()
            let result = try await who.diarize(samples: samples, sampleRate: sampleRate)
            var w = FFIWriter()
            w.u32(result.speakerCount)
            w.u32(result.turns.count)
            for turn in result.turns {
                w.u32(turn.speaker)
                w.f64(turn.start)
                w.f64(turn.end)
            }
            w.f64(result.duration)
            return w.bytes
        } catch {
            return nil
        }
    }

    private func instance() throws -> Who {
        if let who { return who }
        let made = Who(directory: directory, cacheRoot: cacheRoot)
        who = made
        return made
    }
}

/// How the generic bindings construct Who.
public enum WhoBinding: ModelBinding {
    public static let id = WhoModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        WhoBound(cacheRoot: cacheRoot, directory: directory)
    }
}
#endif
