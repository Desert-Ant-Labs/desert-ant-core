// FoundationTransport against the local echo server (Tools/EchoServer.swift,
// which `mise run test:swift` starts on 127.0.0.1:$DAL_ECHO_PORT, 8199 when
// unset, as HTTPTests documents).
// The store's own logic is covered with mock transports; what only a real
// server can show is what the download delegate does with a redirect, which is
// what every Hub weights URL answers with.
//
// macOS and Linux, like HTTPClientTests: those are the hosts where the task
// starts the server and cleartext localhost works.
#if os(macOS) || os(Linux)
import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
private let streamSocketType = SOCK_STREAM
#else
import Glibc
private let streamSocketType = Int32(SOCK_STREAM.rawValue)
#endif
@testable import ModelStore

private let echoPort: UInt16 =
    ProcessInfo.processInfo.environment["DAL_ECHO_PORT"].flatMap { UInt16($0) } ?? 8199
private let echoServer = "http://127.0.0.1:\(echoPort)"

/// Whether the echo server is up. Xcode's test runner doesn't start one (only
/// the mise tasks do), so the suite skips there instead of failing.
private let echoServerIsListening: Bool = {
    let fd = socket(AF_INET, streamSocketType, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = echoPort.bigEndian
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}()

@Suite(.enabled(if: echoServerIsListening, "no echo server on 127.0.0.1:\(echoPort)"))
struct FoundationTransportTests {
    private func temporaryPath() -> String {
        NSTemporaryDirectory() + "dal-transport-\(UUID().uuidString)"
    }

    /// The download must survive the hop: same destination, same progress
    /// closure, one continuation. The delegate follows a redirect on a task of
    /// its own (see `willPerformHTTPRedirection`), so a hop is where all three
    /// would be dropped.
    @Test func aRedirectChainEndsAtTheFile() async throws {
        let dest = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: dest) }
        let reported = Reported()

        try await FoundationTransport().download("\(echoServer)/redirect/2", to: dest,
                                                 onBytes: { reported.append($0) })

        let bytes = try #require(FileManager.default.contents(atPath: dest))
        #expect(bytes == Data(repeating: 0x41, count: 1024))  // what /bytes/1024 serves
        #expect(reported.values.last == 1024)
    }

    /// A chain longer than the delegate's limit has to end as an error. The
    /// failure mode it guards against is the continuation never being resumed,
    /// which is a hung download rather than a failed one.
    @Test func aRedirectLoopFailsRatherThanHanging() async throws {
        let dest = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: dest) }

        await #expect(throws: ModelStoreError.self) {
            try await FoundationTransport().download("\(echoServer)/redirect/99", to: dest,
                                                     onBytes: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: dest))
    }
}

private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [Int64] = []
    func append(_ value: Int64) { lock.withLock { bytes.append(value) } }
    var values: [Int64] { lock.withLock { bytes } }
}
#endif
