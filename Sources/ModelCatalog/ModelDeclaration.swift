// The shared half of a catalog entry. Each model's own module (`Sources/Emo`,
// `Sources/Redact`, ...) holds only its data, so adding a model changes nothing here.

import Foundation
import ModelStore
import Usage

/// One model in the Desert Ant Labs catalog: what it is, where its files come
/// from, and which of them each platform needs.
public protocol ModelDeclaration: Sendable {
    /// Canonical lowercase id: Hub repo suffix, npm/Maven coordinate, directory
    /// name, usage-event name. Everything else derives from it.
    static var id: String { get }
    /// Capitalized name: Swift products, native library names, docs.
    static var product: String { get }
    /// Pinned model revision the SDK is built against (a `v`-prefixed tag).
    static var revision: String { get }
    /// The SDK's released version, as published to npm and Maven, and what usage
    /// attributes to. `ModelCatalogTests` checks it against
    /// `packages/<id>-node/package.json` and `packages/<id>-kotlin/build.gradle.kts`.
    static var sdkVersion: String { get }
    /// One line describing what the model does.
    static var summary: String { get }
    /// Repo-relative entries each platform needs. Directory artifacts (e.g. a
    /// Core ML `.mlmodelc`) end in `/`. A platform absent here is unsupported.
    static var files: [ModelPlatform: [String]] { get }
    /// Repo-relative entries for a runtime other than the platform default (Core
    /// AI on Apple). Empty for a model that ships one artifact per platform.
    static var runtimeFiles: [ModelRuntime: [String]] { get }

    /// The oldest OS this model's artifact runs on. Defaults to the package floor.
    /// `ModelCatalogTests` checks an override against the compiled package.
    static var osFloor: OSFloor { get }
    /// The runnable artifact for `platform`: the file the inference session is
    /// built from, as opposed to the sidecars around it.
    static func artifact(for platform: ModelPlatform) -> String
}

public extension ModelDeclaration {
    /// Hugging Face repo id, e.g. `"desert-ant-labs/redact"`.
    static var repo: String { "desert-ant-labs/\(id)" }

    static var osFloor: OSFloor { .packageFloor }

    static var runtimeFiles: [ModelRuntime: [String]] { [:] }

    /// This SDK's usage identity, sent in every telemetry body's `sdk` field so usage
    /// attributes to this model rather than to the core. Derived, so a model cannot
    /// forget it (which silently bills to the default identity) or let it go stale.
    static var sdkInfo: SDKInfo { SDKInfo(name: product, version: sdkVersion) }

    /// Everything an SDK needs to download, adopt, or verify its model.
    static var distribution: ModelDistribution {
        ModelDistribution(repo: repo, revision: revision, files: files, runtimeFiles: runtimeFiles)
    }

    /// The runnable artifact on the platform being built for.
    static var artifact: String { artifact(for: ModelPlatform.current) }

    /// Whether this model ships anything for `platform`.
    static func supports(_ platform: ModelPlatform) -> Bool { files[platform] != nil }

    /// Resolve the model for `directory` (adopt files you placed there, else
    /// download to it); `nil` uses the managed platform cache.
    static func resolve(
        directory: String? = nil,
        cacheRoot: String? = nil,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws -> StoredModel {
        try await distribution.resolve(cacheDirectory: directory, cacheRoot: cacheRoot, progress: progress)
    }

    /// Whether the model is usable offline for `directory`.
    static func isAvailable(directory: String? = nil, cacheRoot: String? = nil) -> Bool {
        distribution.isAvailable(cacheDirectory: directory, cacheRoot: cacheRoot)
    }
}

/// The oldest OS each Apple platform needs to run a model's artifact.
///
/// The requirement comes from the artifact: a Core ML package records
/// `specificationVersion`, and the runtime refuses to load it below that whatever the SDK
/// claims. Declaring it here lets the catalog be checked against the artifact.
///
/// **This does not gate compilation.** `@available` cannot be computed from a value, so a
/// model that must not compile below some version still annotates its own declarations.
public struct OSFloor: Sendable, Equatable {
    public let iOS: Int
    public let macOS: Int
    public let tvOS: Int
    public let visionOS: Int
    public let watchOS: Int

    public init(iOS: Int, macOS: Int, tvOS: Int, visionOS: Int, watchOS: Int) {
        self.iOS = iOS; self.macOS = macOS; self.tvOS = tvOS
        self.visionOS = visionOS; self.watchOS = watchOS
    }

    /// What the SDK itself supports, for an artifact that adds no requirement.
    public static let packageFloor = OSFloor(iOS: 16, macOS: 13, tvOS: 16, visionOS: 1, watchOS: 9)

    /// A Core ML multifunction package (several graphs over one stored trunk), an iOS 18
    /// feature. Such an artifact reports `specificationVersion` 9.
    public static let multifunction = OSFloor(iOS: 18, macOS: 15, tvOS: 18, visionOS: 2, watchOS: 11)

    /// MLX, which has no build below this.
    public static let mlx = OSFloor(iOS: 17, macOS: 14, tvOS: 17, visionOS: 1, watchOS: 11)

    /// Whether the running OS meets this floor.
    public var isSatisfiedHere: Bool {
        #if os(iOS)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            .init(majorVersion: iOS, minorVersion: 0, patchVersion: 0))
        #elseif os(macOS)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            .init(majorVersion: macOS, minorVersion: 0, patchVersion: 0))
        #elseif os(tvOS)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            .init(majorVersion: tvOS, minorVersion: 0, patchVersion: 0))
        #elseif os(visionOS)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            .init(majorVersion: visionOS, minorVersion: 0, patchVersion: 0))
        #elseif os(watchOS)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            .init(majorVersion: watchOS, minorVersion: 0, patchVersion: 0))
        #else
        return true          // non-Apple platforms do not run Core ML and are not gated by it
        #endif
    }

    /// A sentence a developer can act on, or nil when the OS is new enough.
    public func unmetReason(_ model: String) -> String? {
        isSatisfiedHere ? nil : "\(model) needs iOS \(iOS) / macOS \(macOS) / tvOS \(tvOS) / "
            + "visionOS \(visionOS) / watchOS \(watchOS); this system is older"
    }
}
