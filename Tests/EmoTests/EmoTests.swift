import Foundation
import Testing
import DesertAnt
import TestSupport
@testable import Emo
#if canImport(Glibc)
import Glibc
#endif

// The model-backed tests are wasm-guarded because the shared fixture does not
// exist there (the model store's filesystem and transport come from the JS host
// the app installs, which the bare test harness never does), and skipped off
// iOS/Android by the `.modelBacked` trait. `.serialized` keeps the instances
// from resolving the same model concurrently, the house pattern for model
// suites (see Ear's SmokeTests).
#if !os(WASI)
/// End-to-end suggestion through the downloaded model. On Apple this runs the
/// Core ML artifact; on Linux/Windows the LiteRT artifact (via LiteRT). Both
/// exports come from the same checkpoint and share one fixed-window signature, so
/// the results match.
@Suite(.serialized, .modelBacked)
struct EmoModelTests {
    /// A suggester over the cached model (offline after the fixture's download).
    private func makeEmo() -> Emo { Emo() }

    @Test func englishPredictions() async throws {
        let emo = makeEmo()
        let bills = try await emo.suggestions(for: "Pay my bills", limit: 5).map(\.emoji)
        #expect(bills.contains { ["💰", "💳", "🧾", "🏦", "📄"].contains($0) }, "got \(bills)")
        let dog = try await emo.suggestions(for: "walk the dog", limit: 5).map(\.emoji)
        #expect(dog.contains { ["🐕", "🐾", "🚶"].contains($0) }, "got \(dog)")
        let flight = try await emo.suggestions(for: "book a flight to Tokyo", limit: 5).map(\.emoji)
        #expect(flight.contains("✈️"), "got \(flight)")
    }

    @Test func multilingualPredictions() async throws {
        let emo = makeEmo()
        let walk = try await emo.suggestions(for: "犬の散歩", limit: 5).map(\.emoji)
        #expect(walk.contains { ["🐕", "🐾"].contains($0) }, "got \(walk)")
        let coffee = try await emo.suggestions(for: "café con leche", limit: 5).map(\.emoji)
        #expect(coffee.contains { ["☕", "🍵", "🥛"].contains($0) }, "got \(coffee)")
    }

    @Test func ranking() async throws {
        let results = try await makeEmo().suggestions(for: "Pay my bills", limit: 3)
        #expect(results.count == 3)
        #expect(results[0].confidence >= results[1].confidence)
        #expect(results.allSatisfy { (0...1).contains($0.confidence) })
    }

    @Test func emptyInput() async throws {
        let results = try await makeEmo().suggestions(for: "   ")
        #expect(results.isEmpty)
    }

    /// A model directory the user populated is adopted offline, with no download.
    @Test func prepopulatedDirectoryIsAdopted() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("emo-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ModelFixture.populate(EmoModel.self, into: directory)

        let emo = Emo(directory: directory.path)
        #expect(emo.isDownloaded())
        let results = try await emo.suggestions(for: "Pay my bills", limit: 3)
        #expect(results.count == 3)
    }

    /// The vocab is keyed on a piece's UTF-8 bytes, not on `String`.
    ///
    /// Swift's `String` equality is Unicode canonical equivalence, so a
    /// `[String: Int32]` vocab merges byte-distinct pieces that normalize alike,
    /// and the later id evicts the earlier. This vocab has exactly two such
    /// pairs, both common Vietnamese words, and in both the decomposed entry
    /// holds the higher id, so it would take the key and leave the composed
    /// entry (the only form NFKC can produce) unreachable.
    @Test func vietnameseVocabPiecesAreReachable() async throws {
        let files = try await ModelFixture.files(EmoModel.self)
        let sem = try #require(SemTokenizer(bytes: try files.read(EmoModel.tokenizer)))
        // emo v0.7.0: `▁một` is 688 composed / 39184 decomposed, and `▁ở` is
        // 1493 / 41329. A re-cut vocab moves these, and should fail here loudly.
        #expect(sem.encode("một") == [688])
        #expect(sem.encode("ở") == [1493])
        // Whichever form the caller types, NFKC composes it to the same piece.
        #expect(sem.encode("m\u{006F}\u{0323}\u{0302}t") == sem.encode("m\u{1ED9}t"))
    }
}
#endif

#if os(macOS) || os(Linux)
// In EmoModelTests, so no other Emo load shares this environment or its license slot.
extension EmoModelTests {
    enum LicenseServer: String, CaseIterable, Sendable {
        case silent
        case unavailableAfterTheLoad
    }

    @Test(arguments: LicenseServer.allCases)
    func aFailingLicenseServerChangesNoSuggestion(_ kind: LicenseServer) async throws {
        let text = "Pay my bills"
        let expected = try await Emo().suggestions(for: text, limit: 5)
        let server = try #require(kind == .silent
            ? StubLicenseServer()
            : StubLicenseServer(answer: "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 3600\r\nContent-Type: application/json\r\nContent-Length: 17\r\nConnection: close\r\n\r\n{\"error\":\"retry\"}"))
        defer { server.stop() }

        let keyless = getenv("DAL_API_KEY") == nil
        let (results, abandoned) = try await withEnvironment([
            "DAL_LICENSE_ENDPOINT": server.endpoint,
            "DAL_APP_ID": "ai.desertant.emo.outage.\(UUID().uuidString)",
        ]) {
            // The load alone: resolving the files, building the session (which starts the license
            // check), and the model. Not the first prediction, which is no part of the question.
            let emo = Emo()
            try await emo.download()
            // The stub answers nothing until release(), so a load that waited on the grant could only
            // finish once the client gave up on it. Causal rather than timed, so a busy machine cannot
            // fail it. The grace lets a give-up that preceded the load's return reach the server.
            try await Task.sleep(nanoseconds: 500_000_000)
            let abandoned = server.abandoned
            if keyless {
                #expect(await server.waitUntil { $0.grantArrivedAt != nil }, "no license request reached the server")
            }
            return (try await emo.suggestions(for: text, limit: 5), abandoned)
        }

        #expect(!abandoned, "the load waited on the license server")
        server.release()
        #expect(results.map(\.emoji) == expected.map(\.emoji))
        #expect(zip(results, expected).allSatisfy { abs($0.confidence - $1.confidence) < 1e-5 })
        #expect(results.map(\.emoji).contains { ["💰", "💳", "🧾", "🏦", "📄"].contains($0) }, "got \(results)")
        if keyless, kind == .unavailableAfterTheLoad {
            #expect(await server.waitUntil { $0.answered > 0 }, "the server never sent its 503")
        }
    }
}

private func withEnvironment<T>(_ values: [String: String], _ body: () async throws -> T) async rethrows -> T {
    let saved = values.keys.map { ($0, getenv($0).map { String(cString: $0) }) }
    for (name, value) in values { setenv(name, value, 1) }
    defer {
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
    }
    return try await body()
}

/// A 127.0.0.1 license server that holds Emo's grant open until release(), then closes it or
/// sends `answer`. It records a grant the client gave up on (its own timeout) while held.
private final class StubLicenseServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let answer: String?
    private let lock = NSLock()
    private var released = false
    private var stopped = false
    private var grantAt: ContinuousClock.Instant?
    private var gaveUp = false
    private var replies = 0

    var endpoint: String { "http://127.0.0.1:\(port)/api/v1" }
    var grantArrivedAt: ContinuousClock.Instant? { lock.withLock { grantAt } }
    var abandoned: Bool { lock.withLock { gaveUp } }
    var answered: Int { lock.withLock { replies } }

    init?(answer response: String? = nil) {
        #if canImport(Glibc)
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard listener >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, len) == 0 && listen(listener, 16) == 0 && getsockname(listener, $0, &len) == 0
            }
        }
        guard ok else { close(listener); return nil }
        fd = listener
        port = UInt16(bigEndian: addr.sin_port)
        answer = response
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func release() { lock.withLock { released = true } }

    func stop() { lock.withLock { stopped = true } }

    func waitUntil(_ condition: (StubLicenseServer) -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition(self) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition(self)
    }

    private var isStopped: Bool { lock.withLock { stopped } }
    private var isReleased: Bool { lock.withLock { released || stopped } }

    private func acceptLoop() {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while !isStopped {
            guard poll(&poller, 1, 50) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            var one: Int32 = 1
            #if canImport(Darwin)
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            var wait = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global().async { [self] in serve(client) }
        }
        close(fd)
    }

    private func serve(_ client: Int32) {
        let (target, body) = readRequest(client)
        let now = ContinuousClock.now
        // Other suites load models under this environment too; holding their grants would fill URLSession's six connections to this host.
        guard target.hasSuffix("/license"), (try? JSONDecoder().decode(Grant.self, from: Data(body)))?.model == "emo" else {
            close(client)
            return
        }
        lock.withLock { if grantAt == nil { grantAt = now } }
        // Hold until released. The client sends nothing more while it waits for the response, so a
        // readable socket that reads as end of stream is the client closing: it gave up on the grant.
        var poller = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        while !isReleased {
            guard poll(&poller, 1, 20) > 0 else { continue }
            var byte: UInt8 = 0
            #if canImport(Glibc)
            let peeked = recv(client, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
            #else
            let peeked = recv(client, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            #endif
            if peeked == 0 || (peeked < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                lock.withLock { gaveUp = true }
                close(client)
                return
            }
            if peeked > 0 { Thread.sleep(forTimeInterval: 0.02) }
        }
        if let answer, !isStopped {
            let bytes = Array(answer.utf8)
            #if canImport(Glibc)
            _ = send(client, bytes, bytes.count, Int32(MSG_NOSIGNAL))
            #else
            _ = send(client, bytes, bytes.count, 0)
            #endif
            lock.withLock { replies += 1 }
        }
        close(client)
    }

    private func readRequest(_ client: Int32) -> (target: String, body: [UInt8]) {
        var data: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        var head = 0
        var expected: Int?
        while expected.map({ data.count < $0 }) ?? true {
            let n = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }
            data.append(contentsOf: chunk[0..<n])
            let text = String(decoding: data, as: UTF8.self)
            if expected == nil, let end = text.range(of: "\r\n\r\n") {
                let length = text[..<end.lowerBound].split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                head = text.utf8.distance(from: text.utf8.startIndex, to: end.upperBound)
                expected = head + length
            }
        }
        let line = String(decoding: data, as: UTF8.self).split(separator: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        return (parts.count > 1 ? String(parts[1]) : "", Array(data[min(head, data.count)...]))
    }

    private struct Grant: Decodable {
        let model: String
    }
}
#endif

struct EmoTests {
    @Test func skinTonePostprocessing() {
        #expect("🏃".applyingSkinTone(.medium) == "🏃🏽")
        #expect("🧑‍🍳".applyingSkinTone(.dark) == "🧑🏿‍🍳")
        #expect("✍️".applyingSkinTone(.light) == "✍🏻")
        #expect("🐕".applyingSkinTone(.medium) == "🐕")
    }
}
