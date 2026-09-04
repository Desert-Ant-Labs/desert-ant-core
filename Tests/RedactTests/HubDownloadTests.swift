#if !os(WASI)
import Testing
import TestSupport
@testable import Redact

@Suite(.hubIntegration)
struct HubDownloadTests {
    @Test func downloadThenRedact() async throws {
        try await HubDownloadScenario.run(
            RedactModel.self,
            make: { Redact(directory: $0) },
            isDownloaded: { $0.isDownloaded() },
            download: { try await $0.download(progress: $1) }
        ) { redact, cached in
            let result = try await redact.redaction(
                of: "Email Anna Kovács at anna@example.com about the invoice."
            )
            #expect(result.redactedText.contains("[EMAIL_1]"), "\(result.redactedText)")
            #expect(result.redactedText.contains("[GIVEN_NAME_1]"), "\(result.redactedText)")
            #expect(
                result.items.first { $0.label.rawValue == "EMAIL" }?.original
                    == "anna@example.com"
            )

            let cachedResult = try await cached.redaction(of: "Card 4111111111111111.")
            #expect(
                cachedResult.redactedText.contains("[CREDIT_CARD_1]"),
                "\(cachedResult.redactedText)"
            )
        }
    }
}
#endif
