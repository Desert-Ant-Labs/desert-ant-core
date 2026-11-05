import PlatformSupport
import Testing
@testable import Usage

// Serialized: DesertAnt.apiKey and the log are process-wide state.
@Suite(.serialized) struct DesertAntConfigTests {
    @Test func apiKeySetInCodeWinsOverEnvironment() {
        DesertAnt.apiKey = "pk_test_code"
        defer { DesertAnt.apiKey = nil }
        #expect(hostProvidedApiKey() == "pk_test_code")
    }

    @Test func emptyApiKeyIsTreatedAsUnset() {
        DesertAnt.apiKey = ""
        defer { DesertAnt.apiKey = nil }
        // Falls through to the environment; the suite does not set DAL_API_KEY,
        // so with the empty in-code value skipped this resolves to nil.
        #expect(hostProvidedApiKey() == nil)
    }

    @Test func unsetByDefault() {
        #expect(DesertAnt.apiKey == nil)
    }

    final class Received: @unchecked Sendable {
        var entries: [(LogLevel, String, String)] = []
    }

    @Test func loggerAndLogLevelAreTheLog() {
        let received = Received()
        DesertAnt.logLevel = .info
        DesertAnt.logger = { level, source, message in
            if source == "configtests" { received.entries.append((level, source, message)) }
        }
        defer {
            DesertAnt.logger = nil
            DesertAnt.logLevel = .warning
        }
        #expect(Log.level == .info)
        Log.debug("not this one", source: "configtests")
        Log.info("this one", source: "configtests")
        #expect(received.entries.map(\.2) == ["this one"])
        #expect(received.entries.map(\.0) == [.info])
    }
}
