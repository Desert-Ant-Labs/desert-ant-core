// Clear's side of the cross-language binding: construction, plus the two payload
// schemas that are genuinely model-specific (the options a run takes, and what a
// result looks like). The generic handle lifecycle and the exported symbols live
// in NativeBindings and ClearNative, so this file is only the model's adapter.

import DesertAnt

extension Clear: BoundModel {
    // `isDownloaded()` and `download(progress:)` are Clear's own public API and
    // witness the protocol as they stand.

    /// Input payload: `f32Array samples` (mono), then `f64 sampleRate`.
    ///
    /// Options payload: `f64 strength` (0...1), then the mastering chain as
    /// `f64 integratedLUFS` (NaN bypasses mastering), `f64 truePeakDBTP`,
    /// `f64 maxLoudnessGainDB`. An empty payload means the SDK defaults (full
    /// strength, Apple Podcasts). A host that wants a preset sends that
    /// preset's numbers - the presets themselves are Swift-side, so no id
    /// crosses the boundary and adding one breaks no host.
    ///
    /// Result payload: `f32Array samples` (48 kHz mono), then `f64 sampleRate`,
    /// `f64 durationSec`, `f64 processingSec`, and `f64 measuredLUFS` (NaN when
    /// mastering was disabled).
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        var options = options
        let audio = input.f32Array()
        let sampleRate = input.f64()
        guard !audio.isEmpty, sampleRate > 0 else { return nil }
        var opts = Options.default
        if !options.isEmpty {
            opts.strength = Strength(options.f64())
            let target = options.f64()
            opts.mastering.enabled = !target.isNaN
            if !target.isNaN { opts.mastering.integratedLUFS = target }
            opts.mastering.truePeakDBTP = options.f64()
            opts.mastering.maxLoudnessGainDB = options.f64()
        }
        guard let result = try? await enhance(samples: audio, sampleRate: sampleRate, options: opts) else {
            return nil
        }
        var w = FFIWriter()
        w.f32Array(result.samples)
        w.f64(result.sampleRate)
        w.f64(result.durationSec)
        w.f64(result.processingSec)
        w.f64(result.measuredLUFS ?? .nan)
        return w.bytes
    }
}

/// How the generic bindings construct Clear.
public enum ClearBinding: ModelBinding {
    public static let id = ClearModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Clear(directory: directory, cacheRoot: cacheRoot)
    }
}
