#if !os(WASI)
import Testing
import TestSupport
@_spi(SchemerBindings) @testable import Schemer

@Suite(.hubIntegration)
struct HubDownloadTests {
    @Test func downloadThenExtract() async throws {
        try await HubDownloadScenario.run(
            SchemerModel.self,
            make: { Schemer(directory: $0) },
            isDownloaded: { $0.isDownloaded() },
            download: { try await $0.download(progress: $1) }
        ) { schemer, cached in
            let golden = try Golden.load()
            let c = try #require(golden.cases.first)
            let out = try await schemer.extract(from: c.text, schema: c.schemaValue, now: c.date)
            for spec in c.schema {
                #expect(Golden.Answer(out[spec.name]).matches(c.answers[spec.name]!), "\(spec.name)")
            }
            // The second extractor reads the same directory with no network.
            let offline = try await cached.extract(from: c.text, schema: c.schemaValue, now: c.date)
            #expect(offline.json == out.json)
        }
    }
}
#endif
