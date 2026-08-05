// Skin-tone post-processing is pure stdlib (Unicode scalar arithmetic), so it
// builds unchanged on Apple, Android, and wasm with no Foundation.

/// Preferred emoji skin tone variant for skin-tone-capable emoji.
public enum EmojiSkinTone: Sendable, Equatable {
    /// Default emoji presentation with no skin tone modifier.
    case `default`
    case light
    case mediumLight
    case medium
    case mediumDark
    case dark

    var modifier: UnicodeScalar? {
        switch self {
        case .default: nil
        case .light: UnicodeScalar(0x1F3FB)
        case .mediumLight: UnicodeScalar(0x1F3FC)
        case .medium: UnicodeScalar(0x1F3FD)
        case .mediumDark: UnicodeScalar(0x1F3FE)
        case .dark: UnicodeScalar(0x1F3FF)
        }
    }
}

extension String {
    func applyingSkinTone(_ skinTone: EmojiSkinTone) -> String {
        guard let modifier = skinTone.modifier else { return self }
        let scalars = Array(unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            let value = scalar.value
            if isSkinToneModifier(value) {
                i += 1
                continue
            }
            out.append(scalar)
            if isEmojiModifierBase(value) {
                out.append(modifier)
                while i + 1 < scalars.count {
                    let next = scalars[i + 1].value
                    guard isSkinToneModifier(next) || next == 0xFE0F else { break }
                    i += 1
                }
            }
            i += 1
        }
        return String(out)
    }
}

private func isSkinToneModifier(_ value: UInt32) -> Bool { (0x1F3FB...0x1F3FF).contains(value) }

private func isEmojiModifierBase(_ value: UInt32) -> Bool {
    value == 0x261D || value == 0x26F9 ||
    (0x270A...0x270D).contains(value) || value == 0x1F385 ||
    (0x1F3C2...0x1F3C4).contains(value) || value == 0x1F3C7 ||
    (0x1F3CA...0x1F3CC).contains(value) || (0x1F442...0x1F443).contains(value) ||
    (0x1F446...0x1F450).contains(value) || (0x1F466...0x1F478).contains(value) ||
    value == 0x1F47C || (0x1F481...0x1F483).contains(value) ||
    (0x1F485...0x1F487).contains(value) || value == 0x1F48F || value == 0x1F491 ||
    value == 0x1F4AA || (0x1F574...0x1F575).contains(value) || value == 0x1F57A ||
    value == 0x1F590 || (0x1F595...0x1F596).contains(value) ||
    (0x1F645...0x1F647).contains(value) || (0x1F64B...0x1F64F).contains(value) ||
    value == 0x1F6A3 || (0x1F6B4...0x1F6B6).contains(value) || value == 0x1F6C0 ||
    value == 0x1F6CC || value == 0x1F90C || (0x1F918...0x1F91F).contains(value) ||
    value == 0x1F926 || (0x1F930...0x1F939).contains(value) ||
    (0x1F93D...0x1F93E).contains(value) || value == 0x1F977 ||
    (0x1F9B5...0x1F9B6).contains(value) || (0x1F9B8...0x1F9B9).contains(value) ||
    (0x1F9CD...0x1F9CF).contains(value) || (0x1F9D1...0x1F9DD).contains(value) ||
    (0x1FAF0...0x1FAF8).contains(value)
}
