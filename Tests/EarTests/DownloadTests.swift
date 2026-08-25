import Foundation
import Testing

@testable import Ear

/// The path a caller actually takes: `Ear()`, with nothing on disk.
///
/// Every other test in this suite hands the SDK a directory that already holds
/// the model. That skips resolution, the manifest of per-platform files, the
/// download, and the cache - which is where the names in `Catalog.swift` have to
/// match the names in the published repo. They did not, once: the catalog asked
/// for `detector.mlmodelc` after the artifact had been renamed to
/// `ear.mlmodelc`, and the only symptom was a fall-through to a download.
///
/// Off by default. It reaches the network, and while the weights repo is
/// private it needs a token, so a bare `swift test` must not depend on it:
///
///     EAR_TEST_DOWNLOAD=1 swift test --filter DownloadTests
/// Progress callbacks arrive off the calling thread.
final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    var highest: Double { lock.withLock { value } }
    func observe(_ fraction: Double) { lock.withLock { value = max(value, fraction) } }
}

// Reaches the network and the cache directory, neither of which wasm has
// here.
#if !os(WASI)
@Suite(.enabled(if: EarFixtures.downloadEnabled,
                "reaches the network: set EAR_TEST_DOWNLOAD=1"))
struct DownloadTests {
    /// A cache of its own, so the test measures a real cold download rather than
    /// whatever a previous run left behind.
    static func scratch() -> String {
        let path = NSTemporaryDirectory() + "ear-download-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: path,
                                                 withIntermediateDirectories: true)
        return path
    }

    @Test func downloadsAndThenIdentifies() async throws {
        let cache = Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: cache) }

        let ear = Ear(directory: nil, cacheRoot: cache)
        #expect(!Ear.isDownloaded(cacheRoot: cache), "nothing should be cached yet")

        // Progress arrives on another thread, so it is collected through a
        // lock rather than a captured var.
        let reported = Reported()
        let began = Date()
        try await ear.download { reported.observe($0) }
        print(String(format: "  downloaded in %.1f s, progress reached %.2f",
                     Date().timeIntervalSince(began), reported.highest))

        // A model that reports itself missing right after a successful download
        // means the catalog's file names disagree with the published repo.
        #expect(Ear.isDownloaded(cacheRoot: cache))

        // Whatever it fetched has to be usable, not merely present.
        let samples = (0..<(16000 * 40)).map { n -> Float in
            let t = Double(n) / 16000.0
            let syllable = 0.5 + 0.5 * sin(2.0 * Double.pi * 4.0 * t)
            return Float(syllable) * 0.3 * Float.random(in: -1...1)
        }
        let detection = try await ear.identify(samples: samples, sampleRate: 16000)
        #expect(detection.language != nil)
        #expect(detection.windows >= 1)
        print("  ran on downloaded weights: \(detection.language ?? "-")")
    }

    @Test func aSecondInstanceReusesTheCache() async throws {
        let cache = Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: cache) }

        try await Ear(directory: nil, cacheRoot: cache).download()
        let began = Date()
        try await Ear(directory: nil, cacheRoot: cache).download()
        let seconds = Date().timeIntervalSince(began)
        print(String(format: "  second resolve took %.2f s", seconds))
        // Re-resolving must not re-fetch. A cache that misses looks like a slow
        // network rather than a bug, which is why it is asserted rather than
        // eyeballed.
        #expect(seconds < 5)
    }
}
#endif
