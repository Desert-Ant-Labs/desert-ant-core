// Runs where cleartext localhost works and there's a running echo server:
// macOS/Linux (URLSession) and WASI (Node `fetch`). The tasks (mise run
// test-macos / test-wasi) build Tools/EchoServer.swift and serve 127.0.0.1:8199.
// iOS/tvOS block cleartext HTTP (ATS); Android's client is exercised via the
// instrumented JNI harness instead.
#if os(macOS) || os(Linux) || os(WASI)
import Testing
import PlatformSupport

struct HTTPClientTests {
    static let base = "http://127.0.0.1:8199"

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
