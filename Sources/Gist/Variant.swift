// Unlike clear's variants (separate artifact stems in one flat repo), gist's live
// in separate folders (multilingual at the repo root, English under `en/`), so a
// variant is a path prefix rather than a file-name stem.

import DesertAnt

/// Which published gist model to load.
///
/// The default multilingual model covers 36 topics across 101 languages (~74 MB).
/// The English-only build is the same 36 topics and the same classifier head at
/// ~15 MB, for apps that only ever see English/Latin text. **Other scripts are
/// not covered**: non-Latin input degrades to noise.
public enum GistVariant: String, Sendable, Equatable, CaseIterable, Identifiable {
    /// The full model: 36 topics, 101 languages (~74 MB). The SDK default.
    case multilingual
    /// English-only: same 36 topics and head, ~15 MB. English/Latin text only.
    case english

    public var id: String { rawValue }

    /// The variant a `Gist` uses unless told otherwise.
    public static let `default` = GistVariant.multilingual

    /// Repo-relative path prefix for this variant's files (`""` or `"en/"`).
    public var pathPrefix: String { self == .english ? "en/" : "" }

    public var tokenizer: String { pathPrefix + "gist_tokenizer.bin" }
    public var embedding: String { pathPrefix + "gist_embedding.i8" }
    public var embeddingMeta: String { pathPrefix + "gist_embedding.json" }
    public var config: String { pathPrefix + "gist_config.json" }
    public var taxonomy: String { pathPrefix + "taxonomy.json" }
    /// LiteRT export: Android/Linux/Windows, and LiteRT.js on the web.
    public var tflite: String { pathPrefix + "gist.tflite" }
    /// Core ML export (a directory on the Hub): Apple.
    public var coreML: String { pathPrefix + "gist.mlmodelc" }

    /// The sidecars every platform needs alongside the artifact. The embedding
    /// table is one: the potion stream is a lookup, not a tensor op.
    public var sidecars: [String] { [tokenizer, embedding, embeddingMeta, config, taxonomy] }

    /// The runnable artifact for `platform`.
    public func artifact(for platform: ModelPlatform) -> String {
        platform == .apple ? coreML : tflite
    }

    /// The artifact for the platform being built for.
    public var artifact: String { artifact(for: .current) }

    /// Repo-relative entries each platform needs for this variant.
    public var files: [ModelPlatform: [String]] {
        let liteRT = [tflite] + sidecars
        return [
            .apple: [coreML + "/"] + sidecars,
            .android: liteRT,
            .linux: liteRT,
            .windows: liteRT,
            .web: liteRT,
        ]
    }

    /// This variant's slice of the model repo: the same repo and pinned revision
    /// as the catalog entry, but only this variant's files, so choosing one
    /// variant never downloads the other.
    public var distribution: ModelDistribution { distribution(revision: GistModel.revision) }

    /// The same slice pinned to an explicit repo `revision`. Each revision
    /// caches separately.
    public func distribution(revision: String) -> ModelDistribution {
        ModelDistribution(repo: GistModel.repo, revision: revision, files: files)
    }
}
