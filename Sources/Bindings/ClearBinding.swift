// Clear's side of the cross-language binding: construction, plus the two payload
// schemas that are genuinely model-specific (the options a run takes, and what a
// result looks like). The exported C ABI and JNI entry points beside it are
// shared by every model.
//
// This lives in `Bindings`, not in the model's own module, so a model module
// never references `FFIBuffer`. An app that just imports Clear links no FFI
// layer at all - which also keeps Xcode from having to link a static library
// whose only use is a conformance the app never calls.

import DesertAnt
@_spi(ClearBindings) import Clear

extension Clear: BoundModel {
    // `isDownloaded()` and `download(progress:)` are Clear's own public API and
    // witness the protocol as they stand.

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
    public func run(audio: [Float], sampleRate: Double, options: FFIReader) async -> [UInt8]? {
        var options = options
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
