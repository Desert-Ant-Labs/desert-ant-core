// Emo's side of the cross-language binding: construction, plus the two payload
// schemas that are genuinely model-specific (the options a run takes, and what a
// result looks like). The exported C ABI and JNI entry points beside it are
// shared by every model.
//
// This lives in `Bindings`, not in the model's own module, so a model module
// never references `FFIBuffer`. An app that just imports Emo links no FFI
// layer at all - which also keeps Xcode from having to link a static library
// whose only use is a conformance the app never calls.

import DesertAnt
@_spi(EmoBindings) import Emo

extension Emo: BoundModel {
    /// Options payload: `u32 limit`, `u32 skinTone` (0 default, 1 light,
    /// 2 mediumLight, 3 medium, 4 mediumDark, 5 dark). An empty payload means
    /// the SDK defaults.
    ///
    /// Result payload: `u32 count`, then per suggestion a length-prefixed UTF-8
    /// emoji string and an `f64` confidence.
    public func run(text: String, options: FFIReader) async -> [UInt8]? {
        var options = options
        // An empty payload means the SDK defaults, so this must match the default
        // every SDK declares for `limit` (3), not a number of its own.
        let limit = options.isEmpty ? 3 : options.u32()
        let tone = EmojiSkinTone(ffiValue: options.u32())
        guard let suggestions = try? await suggestions(for: text, limit: limit, skinTone: tone) else {
            return nil
        }
        var w = FFIWriter()
        w.u32(suggestions.count)
        for s in suggestions {
            w.string(s.emoji)
            w.f64(s.confidence)
        }
        return w.bytes
    }
}

private extension EmojiSkinTone {
    init(ffiValue: Int) {
        switch ffiValue {
        case 1: self = .light
        case 2: self = .mediumLight
        case 3: self = .medium
        case 4: self = .mediumDark
        case 5: self = .dark
        default: self = .default
        }
    }
}

/// How the generic bindings construct Emo.
public enum EmoBinding: ModelBinding {
    public static let id = EmoModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Emo(directory: directory, cacheRoot: cacheRoot)
    }
}
