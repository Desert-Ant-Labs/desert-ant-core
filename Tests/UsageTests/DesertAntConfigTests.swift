import Testing
@testable import Usage

// Serialized: DesertAnt.apiKey is process-wide state.
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
}
