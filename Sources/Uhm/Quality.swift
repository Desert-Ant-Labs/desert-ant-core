// Like clear's `ModelVariant`, a quality selects its own slice of the model repo,
// so choosing one tier never downloads the other.

import DesertAnt

extension Uhm {
    // TODO: reinstate `.standard` (case, `stem`, `inferred`) once
    // `uhm-base.mlmodelc` is uploaded and the revision pin is bumped.
    /// Model tier, mirroring the standalone uhm-swift SDK's `Uhm.Quality`.
    ///
    /// uhm-swift also has `.standard` (the HuBERT-base `uhm-base`). Its Core ML
    /// export is not on this Hub repo, so declaring the case would only offer a
    /// download that fails.
    public enum Quality: Sendable, Equatable, Hashable, CaseIterable {
        /// The distilled DistilHuBERT model (smaller, faster, more precise;
        /// uhm-swift's Pro tier, published here as `uhm`).
        case high
        /// Resolves to ``high``, the only published tier.
        case auto

        /// The tier a `Uhm` uses unless told otherwise.
        public static let `default` = Quality.auto

        /// The concrete tier `self` selects (`auto` resolves; the others are
        /// themselves).
        public var resolved: Quality { self == .auto ? .high : self }

        /// The artifact stem on the Hub for the resolved tier.
        var stem: String { "uhm" }

        /// Core ML export (a directory on the Hub), the only published export.
        public var coreML: String { "\(stem).mlmodelc" }

        /// The runnable artifact for `platform`. Only Apple ships, so every
        /// platform answers the Core ML name.
        public func artifact(for platform: ModelPlatform) -> String { coreML }

        /// Repo-relative entries each platform needs for this tier: the
        /// detector plus the tier-independent type-labeler head.
        public var files: [ModelPlatform: [String]] {
            [.apple: [coreML + "/", UhmModel.labeler]]
        }

        /// This tier's slice of the model repo: the same repo and pinned
        /// revision as the catalog entry, but only this tier's files.
        public var distribution: ModelDistribution {
            ModelDistribution(repo: UhmModel.repo, revision: UhmModel.revision, files: files)
        }

        /// The tier an artifact path belongs to, by its file name
        /// (`.../uhm.mlmodelc` -> `.high`), or nil if the name is not a
        /// published tier (a custom or renamed export).
        public static func inferred(fromPath path: String) -> Quality? {
            let name = path.split(separator: "/").last.map(String.init) ?? path
            return name.hasPrefix("uhm.") ? .high : nil
        }
    }
}
