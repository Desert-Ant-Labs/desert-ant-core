// This model's catalog declaration. Tongue is bundled, not downloaded: the
// whole model is 2 MB of int8 weights plus a metadata JSON, shipped inside
// every package (a SwiftPM target resource, the npm package's dist/, the jar's
// resources). No Hugging Face repo exists, so no ModelStore path ever resolves
// this manifest, and there is no HubDownloadTests here on purpose.

import DesertAnt

/// The tongue model: on-device language identification for short text.
public enum TongueModel: ModelDeclaration {
    public static let id = "tongue"
    public static let product = "Tongue"
    /// No Hub repo exists (the weights ship inside the packages), so there is
    /// no v-tag to pin; `main` is the documented placeholder the catalog
    /// invariants accept.
    public static let revision = "main"
    /// Matches packages/tongue-node/package.json and
    /// packages/tongue-kotlin/build.gradle.kts (ModelCatalogTests enforces it).
    public static let sdkVersion = "1.2.0"
    public static let summary = "On-device language identification for short text across 84 languages."

    /// The int8 embedding table and head; `Model.swift` documents the layout.
    public static let weights = "tongue_int8.bin"
    /// Vocabulary hashing constants, the language list, and calibration.
    public static let meta = "tongue_meta.json"

    /// The same two files everywhere: every platform bundles them rather than
    /// downloading them. The Kotlin port covers Android and the JVM, the
    /// TypeScript port covers web and Node, and the Swift target covers Apple
    /// platforms and Linux.
    public static let files: [ModelPlatform: [String]] = [
        .apple: [weights, meta],
        .android: [weights, meta],
        .linux: [weights, meta],
        .web: [weights, meta],
    ]

    public static func artifact(for platform: ModelPlatform) -> String { weights }
}
