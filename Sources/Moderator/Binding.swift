// Moderator's side of the cross-language binding: construction, plus the payload
// schemas that are model-specific (the image a run takes, its options, and the
// result). The handle lifecycle and exported symbols live in NativeBindings and
// Native.swift.

import DesertAnt

extension Moderator: BoundModel {
    /// Input payload: `u32 width`, `u32 height`, `u32 channels` (3 RGB or 4
    /// RGBA), then a length-prefixed blob of `width * height * channels` bytes.
    ///
    /// Options payload: `f64 threshold`, `u32 policy` (0 standard, 1
    /// allowTopless), `u32 quality` (0 fast, 1 balanced, 2 accurate). An empty
    /// payload means the SDK defaults.
    ///
    /// Result payload: `f64 score`, `u32 isNSFW`, then `f64` nipples, genitals,
    /// buttocks, nude, sexAct.
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        var options = options
        let width = input.u32(), height = input.u32(), channels = input.u32()
        guard let image = try? ImagePixels(width: width, height: height, channels: channels,
                                           bytes: input.blob()) else { return nil }
        let opts = options.isEmpty ? Options() : Options(
            threshold: options.f64(),
            policy: Policy(rawValue: options.u32()) ?? .standard,
            quality: Quality(rawValue: options.u32()) ?? .accurate)
        guard let result = try? await analyze(image, options: opts) else { return nil }

        var w = FFIWriter()
        w.f64(result.score)
        w.u32(result.isNSFW ? 1 : 0)
        let r = result.regions
        for value in [r.nipples, r.genitals, r.buttocks, r.nude, r.sexAct] { w.f64(value) }
        return w.bytes
    }
}

/// How the generic bindings construct Moderator.
public enum ModeratorBinding: ModelBinding {
    public static let id = ModeratorModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Moderator(directory: directory, cacheRoot: cacheRoot)
    }
}
