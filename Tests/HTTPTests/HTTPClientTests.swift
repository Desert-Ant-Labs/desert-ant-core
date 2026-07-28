// Runs where cleartext localhost works and there's a running echo server:
// macOS/Linux (URLSession) and WASI (Node `fetch`). The tasks (mise run
// test-macos / test-wasi) build Tools/EchoServer.swift and serve 127.0.0.1:8199.
// iOS/tvOS block cleartext HTTP (ATS); Android's client is exercised via the
// instrumented JNI harness instead.
#if os(macOS) || os(Linux) || os(WASI)
import Testing
import PlatformSupport

#if os(macOS)
import Foundation

/// Manages an EchoServer subprocess when the suite runs under Xcode.
///
/// The mise tasks (test-macos / test-wasi) build and start Tools/EchoServer.swift
/// themselves. Xcode's test runner doesn't, so when we detect an Xcode-launched
/// process we compile and start it here, and tear it down when the suite ends.
final class EchoServerFixture: @unchecked Sendable {
    static let shared = EchoServerFixture()

    /// True when the process was launched by Xcode (not `swift test` / mise).
    static var isRunningInXcode: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["__CFBundleIdentifier"] == "com.apple.dt.Xcode"
            || env["XCODE_VERSION_ACTUAL"] != nil
    }

    private var process: Process?

    private init() {
        guard Self.isRunningInXcode else { return }
        start()
    }

    private func start() {
        // A server may already be listening (a previous run, or one that mise
        // started). Reuse it rather than binding again and crashing on EADDRINUSE.
        if canConnect(host: "127.0.0.1", port: 8199) { return }
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("echo-server-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let bin = dir.appendingPathComponent("EchoServer")
            let source = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tools/EchoServer.swift")

            // Xcode's test host injects SDKROOT / build env vars that make a plain
            // `xcrun swiftc` pick the wrong SDK and fail. Scrub them so the build
            // behaves like a clean shell.
            var env = ProcessInfo.processInfo.environment
            for key in ["SDKROOT", "DEVELOPER_DIR", "TOOLCHAINS",
                        "SWIFT_EXEC", "LIBRARY_PATH", "CPATH"] {
                env.removeValue(forKey: key)
            }

            let build = Process()
            build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            build.arguments = ["swiftc", "-O", source.path, "-o", bin.path]
            build.environment = env
            let buildErr = Pipe()
            build.standardError = buildErr
            try build.run()
            build.waitUntilExit()
            guard build.terminationStatus == 0 else {
                let msg = String(decoding: buildErr.fileHandleForReading.readDataToEndOfFile(),
                                 as: UTF8.self)
                fatalError("EchoServer build failed (\(build.terminationStatus)):\n\(msg)")
            }

            let server = Process()
            server.executableURL = bin
            server.arguments = ["8199"]
            server.environment = env
            try server.run()
            process = server

            // `deinit` is not guaranteed to run at process exit, which would leak
            // the server and hold port 8199 (breaking the next test run). Register
            // an atexit handler so the child is always reaped.
            EchoServerFixture.registerCleanup(pid: server.processIdentifier)

            // Wait until the port actually accepts a TCP connection.
            var ready = false
            for _ in 0..<50 {
                guard server.isRunning else {
                    fatalError("EchoServer exited early (status \(server.terminationStatus)); "
                        + "is port 8199 already in use?")
                }
                if canConnect(host: "127.0.0.1", port: 8199) { ready = true; break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard ready else { fatalError("EchoServer did not become reachable on 127.0.0.1:8199") }
        } catch {
            fatalError("Failed to start EchoServer for Xcode run: \(error)")
        }
    }

    private func canConnect(host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    deinit {
        process?.terminate()
    }

    /// PIDs to SIGTERM at process exit. A plain C-function `atexit` callback can't
    /// capture context, so the pid is stashed in a static and killed from there.
    nonisolated(unsafe) private static var cleanupPID: pid_t = 0
    private static func registerCleanup(pid: pid_t) {
        cleanupPID = pid
        atexit {
            if EchoServerFixture.cleanupPID > 0 {
                kill(EchoServerFixture.cleanupPID, SIGTERM)
            }
        }
    }
}
#endif

struct HTTPClientTests {
    static let base = "http://127.0.0.1:8199"

    #if os(macOS)
    // Touching `.shared` starts the fixture once (no-op outside Xcode).
    static let fixture = EchoServerFixture.shared
    init() { _ = Self.fixture }
    #endif

    @Test func postEchoesBodyAndContentType() async throws {
        let sent = Array(#"{"ping":true}"#.utf8)
        let response = try await httpPOST("\(Self.base)/echo", body: sent, contentType: "application/json")
        #expect(response.status == 200)
        #expect(response.body == sent)                          // body relayed
        #expect(response.header("Content-Type") == "application/json") // header relayed
    }

    @Test func getReturnsOKWithEmptyBody() async throws {
        let response = try await httpGET("\(Self.base)/health")
        #expect(response.status == 200)
        #expect(response.body.isEmpty)
    }
}
#endif
