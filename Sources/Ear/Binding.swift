// Ear's side of the cross-language binding: construction, plus the two payload
// schemas that are genuinely model-specific (what a run takes, and what a result
// looks like). The generic handle lifecycle and the exported symbols live in
// NativeBindings and EarNative, so this file is only the model's adapter.

import DesertAnt

extension Ear: BoundModel {
    // `isDownloaded()` and `download(progress:)` are Ear's own public API and
    // witness the protocol as they stand.

    /// Input payload: `f32Array` samples (mono), then `f64 sampleRate`.
    ///
    /// Mono because language identification reads broad spectral shape and a
    /// second channel adds nothing but bytes to marshal. A host with stereo
    /// downmixes before it calls, which it has to do for its own frontend
    /// anyway.
    ///
    /// Options payload: `f64 windows`, how many thirty-second windows to listen
    /// to. An empty payload means the SDK default, which is three.
    ///
    /// Result payload: `u32 count`, then that many `(string language, f64
    /// probability)` pairs most-likely first, then `f64 windows` actually
    /// listened to and `f64 reliable` (1 or 0).
    ///
    /// `isReliable` crosses as a number rather than being recomputed per host:
    /// the rule behind it is measured, not obvious - a margin under 0.25, or any
    /// answer in the Nordic group, which the model confuses confidently rather
    /// than uncertainly - and three hosts reimplementing it is three chances to
    /// get it wrong.
    ///
    /// Every group is appended, never reordered, so a host built against an
    /// earlier schema keeps reading the prefix it knows.
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        var options = options

        let samples = input.f32Array()
        let sampleRate = input.f64()
        guard !samples.isEmpty, sampleRate > 0 else { return nil }

        var windows = Ear.defaultWindows
        if !options.isEmpty {
            let requested = Int(options.f64())
            if requested > 0 { windows = requested }
        }

        guard let detection = try? await identify(samples: samples, sampleRate: sampleRate,
                                                  windows: windows) else {
            return nil
        }

        var w = FFIWriter()
        w.u32(detection.candidates.count)
        for candidate in detection.candidates {
            w.string(candidate.language)
            w.f64(candidate.probability)
        }
        w.f64(Double(detection.windows))
        w.f64(detection.isReliable ? 1 : 0)
        return w.bytes
    }
}

/// How the generic bindings construct Ear.
public enum EarBinding: ModelBinding {
    public static let id = EarModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Ear(directory: directory, cacheRoot: cacheRoot)
    }
}
