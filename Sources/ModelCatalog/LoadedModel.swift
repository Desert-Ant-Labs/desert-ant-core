// The shell every model SDK wraps: resolve the model's files, build the model
// once, share that single load, and answer "is it available offline?".
//
// Each SDK used to write this itself - a `LazyLoader`, three initializers, an
// availability closure, `isDownloaded`, `download`, `waitUntilLoaded`, and a
// pair of resolve/availability helpers over its `ModelDistribution` - about 120
// lines that differed only in the model type they built. It is also where a
// model could go subtly wrong: forgetting the binding initializer that takes a
// `cacheRoot` silently breaks Android and Node, where the platform has no cache
// base of its own.
//
// So it lives here once, and an SDK keeps only what is genuinely its own: its
// public API, and how a resolved directory becomes its runtime.
//
//     public final class Emo: @unchecked Sendable {
//         private let model: LoadedModel<Model>
//         public convenience init(directory: String? = nil) {
//             self.init(directory: directory, cacheRoot: nil)
//         }
//         public init(directory: String?, cacheRoot: String?) {
//             model = LoadedModel(EmoModel.self, directory: directory, cacheRoot: cacheRoot) {
//                 try Model(assets: await .emo(files: $0))
//             }
//         }
//         public func suggestions(...) async throws -> [EmoSuggestion] {
//             try await model.value().suggestions(...)
//         }
//     }

import ModelStore
import PlatformSupport

/// A model SDK's loaded runtime: `StoredModel` is the files on disk, this is the
/// thing built from them. Construction starts nothing; the first ``value()`` or
/// ``download(progress:)`` resolves the files (adopting `directory`, else
/// downloading into it or into the managed cache) and builds the runtime once,
/// sharing that single load with every concurrent caller. A failed load is not
/// cached, so a later call retries.
public final class LoadedModel<Runtime: Sendable>: @unchecked Sendable {
    private let loader: LazyLoader<Runtime>
    private let availability: @Sendable () -> Bool

    /// Load from the model's own files.
    ///
    /// - Parameters:
    ///   - declaration: the model's catalog entry, which supplies the repo,
    ///     pinned revision, and this platform's file list.
    ///   - directory: where the model lives. Files already there are adopted and
    ///     used offline; otherwise the model is downloaded into it. `nil` uses
    ///     the managed per-model/revision cache.
    ///   - cacheRoot: the platform base the managed cache lives under (the app
    ///     cache dir on Android, `~/.cache` on Node). `nil` on Apple/Linux, where
    ///     the platform provides one.
    ///   - build: turn the resolved files into the runtime.
    public convenience init<Declaration: ModelDeclaration>(
        _ declaration: Declaration.Type,
        directory: String? = nil,
        cacheRoot: String? = nil,
        build: @escaping @Sendable (StoredModel) async throws -> Runtime
    ) {
        self.init(Declaration.distribution, directory: directory, cacheRoot: cacheRoot, build: build)
    }

    /// Load from an explicit distribution, for a model that publishes more than
    /// one artifact set under the same catalog entry (clear's studio/natural
    /// variants): the declaration names the default, and a caller selecting
    /// another passes that variant's own slice of the repo, so choosing one
    /// never downloads the other. Otherwise identical to the declaration form.
    public init(
        _ distribution: ModelDistribution,
        directory: String? = nil,
        cacheRoot: String? = nil,
        build: @escaping @Sendable (StoredModel) async throws -> Runtime
    ) {
        loader = LazyLoader { progress in
            let files = try await distribution.resolve(
                cacheDirectory: directory, cacheRoot: cacheRoot) { progress($0.fraction) }
            return try await build(files)
        }
        availability = { distribution.isAvailable(cacheDirectory: directory, cacheRoot: cacheRoot) }
    }

    /// Wrap a runtime the caller already has the inputs for (the cross-language
    /// bindings' assets path, and the wasm host's self-hosted files): nothing to
    /// resolve or download, but still built lazily and only once, so a failure
    /// surfaces from the same calls as the downloading path.
    public init(_ build: @escaping @Sendable () throws -> Runtime) {
        loader = LazyLoader { _ in try build() }
        availability = { true }
    }

    /// Whether the model is usable with no network: present in its directory, or
    /// cached and intact.
    public func isDownloaded() -> Bool { availability() }

    /// Resolve and build ahead of time, so the first ``value()`` is instant.
    /// Reports progress `0...1`. Concurrent calls, and an implicit load from a
    /// first use, share one download.
    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try await loader.run(progress: progress)
    }

    /// The runtime, loading it on first use.
    public func value() async throws -> Runtime { try await loader.value() }
}
