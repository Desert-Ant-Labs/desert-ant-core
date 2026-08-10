// Uhm's side of the cross-language binding: construction, plus the two payload
// schemas that are genuinely model-specific (the options a run takes, and what a
// result looks like). The generic handle lifecycle and the exported symbols live
// in NativeBindings and UhmNative, so this file is only the model's adapter.

import DesertAnt

extension Uhm: BoundModel {
    // `isDownloaded()` and `download(progress:)` are Uhm's own public API and
    // witness the protocol as they stand.

    /// Input payload: `f32Array samples` (mono), then `f64 sampleRate`.
    ///
    /// Options payload: `f64 minConfidence` (NaN means the balanced preset),
    /// then `f64 minDurationSec` (NaN means the SDK default), then
    /// `u32 includeTypes` (0/1). An empty payload means the SDK defaults.
    /// The bias presets themselves are Swift-side numbers, so no preset id
    /// crosses the boundary and adding one breaks no host.
    ///
    /// Result payload: `f64 audioDuration`, then `u32 count`, then per
    /// detection `f64 start`, `f64 end`, `f64 confidence`, and a
    /// length-prefixed UTF-8 type string (empty when no type was assigned).
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        var options = options
        let samples = input.f32Array()
        let sampleRate = input.f64()
        guard !samples.isEmpty, sampleRate > 0 else { return nil }
        var opts = Options.default
        if !options.isEmpty {
            let minConfidence = options.f64()
            if !minConfidence.isNaN { opts.minConfidence = minConfidence }
            let minDuration = options.f64()
            if !minDuration.isNaN { opts.minDurationSec = minDuration }
            opts.includeTypes = options.u32() != 0
        }
        guard let result = try? await analyze(samples: samples,
                                              sampleRate: Int(sampleRate.rounded()),
                                              options: opts) else {
            return nil
        }
        var w = FFIWriter()
        w.f64(result.audioDuration)
        w.u32(result.fillers.count)
        for f in result.fillers {
            w.f64(f.start)
            w.f64(f.end)
            w.f64(f.confidence)
            w.string(f.type?.rawValue ?? "")
        }
        return w.bytes
    }
}

/// How the generic bindings construct Uhm.
public enum UhmBinding: ModelBinding {
    public static let id = UhmModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Uhm(directory: directory, cacheRoot: cacheRoot)
    }
}
