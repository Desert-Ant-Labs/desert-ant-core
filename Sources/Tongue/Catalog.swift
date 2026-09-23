// Tongue is bundled, not downloaded: 2 MB of int8 weights plus a metadata JSON,
// shipped inside every package (a SwiftPM target resource, the npm package's
// dist/, the jar's resources). The Hub repo mirrors the same bytes for the
// website demo, but no SDK resolves this manifest, so there are no Hub download
// tests for it.

import DesertAnt

/// The tongue model: on-device language identification for short text.
public enum TongueModel: ModelDeclaration {
    public static let id = "tongue"
    public static let product = "Tongue"
    /// The Hub tag pinning the mirrored weights (sha256-identical to the
    /// bundled copies). The SDKs never download them; the website demo does,
    /// and pins this tag rather than trailing main.
    public static let revision = "v1.0.0"
    public static let sdkVersion = "3.5.0"
    public static let summary = "On-device language identification for short text across 84 languages."

    /// The int8 embedding table and head; `Model.swift` documents the layout.
    public static let weights = "tongue_int8.bin"
    /// Vocabulary hashing constants, the language list, and calibration.
    public static let meta = "tongue_meta.json"

    /// The same two bundled files everywhere. The Kotlin port covers Android and
    /// the JVM, the TypeScript port web and Node, the Swift target Apple and Linux.
    public static let files: [ModelPlatform: [String]] = [
        .apple: [weights, meta],
        .android: [weights, meta],
        .linux: [weights, meta],
        .web: [weights, meta],
    ]

    public static func artifact(for platform: ModelPlatform) -> String { weights }
}
