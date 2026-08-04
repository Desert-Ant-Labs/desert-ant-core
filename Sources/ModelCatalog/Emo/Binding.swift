// Emo's side of the cross-language binding: construction, plus the two payload
// schemas that are genuinely model-specific (the options a run takes, and what a
// result looks like). The exported C ABI and JNI entry points are shared by every
// model and live in Sources/Bindings.

import DesertAnt

extension Emo: BoundModel {
    /// `download(progress:)`'s defaulted argument does not witness the
    /// no-argument requirement, so forward explicitly. The host reports progress
    /// through its own channel, not this call.
    public func download() async throws { try await download(progress: { _ in }) }

    /// Options payload: `u32 limit`, `u32 skinTone` (0 default, 1 light,
    /// 2 mediumLight, 3 medium, 4 mediumDark, 5 dark). An empty payload means
    /// the SDK defaults.
    ///
    /// Result payload: `u32 count`, then per suggestion a length-prefixed UTF-8
    /// emoji string and an `f64` confidence.
    public func run(text: String, options: FFIReader) async -> [UInt8]? {
        var options = options
        let limit = options.isEmpty ? 5 : options.u32()
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

    public static func make(files: [String: [UInt8]], modelPath: String?) throws -> any BoundModel {
        guard let meta = files[EmoModel.meta], let tokenizer = files[EmoModel.tokenizer] else {
            throw EmoError.modelNotFound
        }
        let metaJSON = String(decoding: meta, as: UTF8.self)
        if let modelPath {
            return Emo(assets: try ModelAssets(
                metaJSON: metaJSON, tokenizerBytes: tokenizer, modelPath: modelPath))
        }
        guard let model = files[EmoModel.tflite] else { throw EmoError.modelNotFound }
        return Emo(assets: try ModelAssets(
            metaJSON: metaJSON, tokenizerBytes: tokenizer, modelBytes: model))
    }
}
