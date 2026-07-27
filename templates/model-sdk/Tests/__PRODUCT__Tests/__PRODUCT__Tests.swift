import Testing
@testable import __PRODUCT__

// Skeleton suite. Replace with real pipeline tests as `run` is implemented;
// `mise run test-swift` executes these on macOS (Core ML) and Linux (LiteRT).

@Test func emptyInputReturnsNil() async throws {
    let core = __PRODUCT__(assets: .init(metaJSON: "{}", session: StubSession()))
    #expect(try await core.run("") == nil)
}

@Test func resultCarriesLabelAndConfidence() {
    let r = __PRODUCT__Result(label: "a", confidence: 0.5)
    #expect(r.label == "a")
    #expect(r.confidence == 0.5)
}
