#if !os(WASI)
import Foundation
import XCTest
import DesertAnt

/// The Hub integration scenario shared by every model SDK.
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
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HF_INTEGRATION"] == "1",
            "set HF_INTEGRATION=1 to run the network test"
        )

        let directory = NSTemporaryDirectory() + "\(declaration.id)-hub-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let first = make(directory)
        XCTAssertFalse(isDownloaded(first))
        XCTAssertFalse(declaration.isAvailable(directory: directory))

        let progress = ProgressValues()
        try await download(first) { progress.append($0) }

        let values = progress.snapshot
        XCTAssertEqual(values.last, 1)
        XCTAssertTrue(values.allSatisfy { (0...1).contains($0) })
        XCTAssertEqual(values, values.sorted(), "download progress must be monotonic")
        XCTAssertTrue(isDownloaded(first))
        XCTAssertTrue(declaration.isAvailable(directory: directory))

        let cached = make(directory)
        XCTAssertTrue(isDownloaded(cached))
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
