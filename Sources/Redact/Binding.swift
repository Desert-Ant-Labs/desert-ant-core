// Redact's side of the cross-language binding: construction, plus the two payload
// schemas that are genuinely model-specific (the options a run takes, and what a
// result looks like). The generic handle lifecycle and the exported symbols live
// in NativeBindings and RedactNative, so this file is only the model's adapter.

import DesertAnt

extension Redact: BoundModel {
    /// Options payload: `f64 minimumConfidence`, then `u32 labelCount` and that
    /// many length-prefixed label names (an empty list means every label). An
    /// empty payload means the SDK defaults.
    ///
    /// Input payload: `string text`.
    ///
    /// Result payload: the length-prefixed redacted text, `u32 itemCount`, then
    /// per item the label, original, and placeholder strings, an `f64`
    /// confidence, and the UTF-16 start/end offsets as `u32`s.
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        var options = options
        let text = input.string()
        let resolved: Options
        if options.isEmpty {
            resolved = Options()
        } else {
            let minimumConfidence = options.f64()
            let names = options.strings()
            resolved = Options(
                minimumConfidence: minimumConfidence,
                labels: names.isEmpty ? nil : Set(names.compactMap(Label.init(rawValue:))))
        }
        guard let r = try? await redaction(of: text, options: resolved) else { return nil }

        var w = FFIWriter()
        w.string(r.redactedText)
        w.u32(r.items.count)
        for item in r.items {
            w.string(item.label.rawValue)
            w.string(item.original)
            w.string(item.placeholder)
            w.f64(item.confidence)
            w.u32(item.range.lowerBound.utf16Offset(in: text))
            w.u32(item.range.upperBound.utf16Offset(in: text))
        }
        return w.bytes
    }
}

/// How the generic bindings construct Redact.
public enum RedactBinding: ModelBinding {
    public static let id = RedactModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Redact(directory: directory, cacheRoot: cacheRoot)
    }
}
