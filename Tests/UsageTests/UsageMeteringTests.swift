import Testing
@testable import Usage

/// A client built the way every SDK builds one always records and sends.
struct UsageMeteringTests {
    @Test func aClientAlwaysReportsARecordedCall() {
        var sent: [IngestBody] = []
        let client = makeClient(
            appId: "co.acme.metering", platform: "test", storage: InMemoryStorage(),
            send: { body, _ in sent.append(body) }
        )
        client.start()
        client.recordCall()
        client.flush()
        #expect(sent.count == 1, "the client did not report")
        #expect(sent.first?.events.first?.callCount == 1)
    }

    /// The real transport dispatches every send it is handed.
    @Test func theTransportAlwaysSends() async {
        let registry = InflightSends()
        // Nothing listens on port 1, so the send fails at once.
        let send = makeSend(endpoint: "http://127.0.0.1:1/ingest", registry: registry)
        send(IngestBody(sentAt: "t", events: [IngestEvent(deviceId: "d")]), SendOptions())
        #expect(registry.registeredTotal == 1, "the transport did not send")
        for task in registry.drain() { await task.value }
    }
}
