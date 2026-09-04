#if !os(WASI)
import Foundation
import Testing
import DesertAnt

public extension Trait where Self == ConditionTrait {
    /// The Hub integration tests reach the network; opt in per run.
    static var hubIntegration: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["HF_INTEGRATION"] == "1",
            "set HF_INTEGRATION=1 to run the network test")
    }
}

/// The Hub integration scenario shared by every model SDK. Callers gate the
/// test with the `.hubIntegration` trait; this runs the shared assertions.
public enum HubDownloadScenario {
    /// Download through the public SDK, verify its offline checks, construct a
    /// second SDK over the same directory, then run model-specific assertions.
    public static func run<Declaration: ModelDeclaration, SDK>(
        _ declaration: Declaration.Type,
        make: (String) -> SDK,
        isDownloaded: (SDK) -> Bool,
        download: (SDK, @escaping @Sendable (Double) -> Void) async throws -> Void,
        verify: (SDK, SDK) async throws -> Void
    ) async throws {
        let directory = NSTemporaryDirectory() + "\(declaration.id)-hub-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let first = make(directory)
        #expect(!isDownloaded(first))
        #expect(!declaration.isAvailable(directory: directory))

        let progress = ProgressValues()
        try await download(first) { progress.append($0) }

        let values = progress.snapshot
        #expect(values.last == 1)
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(values == values.sorted(), "download progress must be monotonic")
        #expect(isDownloaded(first))
        #expect(declaration.isAvailable(directory: directory))

        let cached = make(directory)
        #expect(isDownloaded(cached))
        try await verify(first, cached)
    }
}

private final class ProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ value: Double) {
        lock.withLock { values.append(value) }
    }

    var snapshot: [Double] {
        lock.withLock { values }
    }
}
#endif
