#if !os(WASI)
import Foundation
import PlatformSupport
import Testing
@testable import Usage

private struct LicenseVectors: Decodable {
    struct Key: Decodable {
        var kid: String
        var publicKeyX963: String
    }

    struct Period: Decodable {
        var serverTime: String
        var period: String
        var periodEnd: String
    }

    struct Token: Decodable {
        struct Payload: Decodable {
            var lid: String
            var period: String
            var periodEnd: String
            var iat: Int64
        }

        var name: String
        var token: String
        var expect: String
        var payload: Payload?
    }

    struct Rule: Decodable {
        var status: Int
        var dalErrorBody: Bool
        var action: String
    }

    var keys: [Key]
    var periods: [Period]
    var tokens: [Token]
    var sdkResponseRules: [Rule]

    static func load() throws -> LicenseVectors {
        let url = try #require(Bundle.module.url(forResource: "license_vectors", withExtension: "json"),
                               "license_vectors.json missing from the test bundle")
        return try JSONDecoder().decode(LicenseVectors.self, from: Data(contentsOf: url))
    }

    var publicKeys: [String: String] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0.kid, $0.publicKeyX963) })
    }

    func token(_ name: String) throws -> String {
        try #require(tokens.first { $0.name == name }?.token)
    }
}

@Suite struct LicenseVectorTests {
    @Test func responseRulesClassifyAsTheVectorsSay() throws {
        let vectors = try LicenseVectors.load()
        #expect(vectors.sdkResponseRules.count >= 10)
        for rule in vectors.sdkResponseRules {
            let body = rule.dalErrorBody ? #"{"error":"invalid_request","message":"bad"}"# : "<html>Bad Gateway</html>"
            let action = licenseResponseAction(status: rule.status, body: Array(body.utf8))
            #expect(action.rawValue == rule.action, "status \(rule.status), dal body \(rule.dalErrorBody)")
        }
    }

    @Test func vectorKeysAreUncompressedP256Points() throws {
        for key in try LicenseVectors.load().keys {
            let bytes = try #require(base64Decode(key.publicKeyX963))
            #expect(bytes.count == 65 && bytes.first == 0x04, "\(key.kid)")
        }
    }

    @Test func periodsEndOneMonthAfterTheServerTime() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let periods = try LicenseVectors.load().periods
        #expect(periods.count >= 12)
        for period in periods {
            let serverTime = try #require(parseISO8601(period.serverTime))
            let end = try #require(parseISO8601(period.periodEnd))
            let issued = Date(timeIntervalSince1970: Double(serverTime / 1000))
            let oneMonthLater = try #require(utc.date(byAdding: .month, value: 1, to: issued))
            #expect(end == Int64(oneMonthLater.timeIntervalSince1970) * 1000, "\(period.serverTime)")
            #expect(!period.periodEnd.contains("."), "\(period.serverTime)")
            #expect(iso8601(epochMs: serverTime).hasPrefix(period.period))
        }
    }

    @Test func validTokensCarryTheirPayload() throws {
        for vector in try LicenseVectors.load().tokens where vector.expect == "valid" {
            let token = try #require(LicenseToken(vector.token), "\(vector.name)")
            let payload = try #require(vector.payload)
            #expect(token.payload.lid == payload.lid)
            #expect(token.payload.period == payload.period)
            #expect(token.payload.periodEnd == payload.periodEnd)
            #expect(token.payload.iat == payload.iat)
            #expect(token.payload.v == 1)
        }
    }

    @Test func withoutAVerifierOnlyTheShapeIsChecked() async throws {
        let shapeOnly: Set<String> = ["bad-signature", "tampered-payload", "unknown-kid"]
        for vector in try LicenseVectors.load().tokens {
            var accepted = false
            if let token = LicenseToken(vector.token) {
                accepted = await verifyLicenseToken(token, publicKeys: [:], verifier: nil)
            }
            #expect(accepted == (vector.expect == "valid" || shapeOnly.contains(vector.name)), "\(vector.name)")
        }
    }

    #if canImport(CryptoKit) || os(Windows)
    @Test func everyVectorTokenVerifiesAsExpected() async throws {
        let vectors = try LicenseVectors.load()
        #expect(vectors.tokens.count >= 10)
        for vector in vectors.tokens {
            var accepted = false
            if let token = LicenseToken(vector.token) {
                accepted = await verifyLicenseToken(token, publicKeys: vectors.publicKeys, verifier: defaultLicenseVerifier())
            }
            #expect(accepted == (vector.expect == "valid"), "\(vector.name)")
        }
    }

    @Test func malformedKeysAndSignaturesAreRejected() async throws {
        let vectors = try LicenseVectors.load()
        let token = try #require(LicenseToken(try vectors.token("valid")))
        let key = try #require(vectors.publicKeys[token.header.kid].flatMap { base64Decode($0) })
        let other = try #require(vectors.publicKeys.first { $0.key != token.header.kid }.flatMap { base64Decode($0.value) })
        let verifier = try #require(defaultLicenseVerifier())
        #expect(await verifier.isValidSignature(token.signature, for: token.signingInput, publicKey: key))
        #expect(await !verifier.isValidSignature(token.signature, for: token.signingInput, publicKey: other))
        #expect(await !verifier.isValidSignature(token.signature, for: token.signingInput, publicKey: Array(key.dropFirst())))
        #expect(await !verifier.isValidSignature(token.signature, for: token.signingInput, publicKey: [0x04] + [UInt8](repeating: 1, count: 64)))
        #expect(await !verifier.isValidSignature(Array(token.signature.dropLast()), for: token.signingInput, publicKey: key))
    }

    @Test func theProductionKeySetRejectsTheTestKeys() async throws {
        let vectors = try LicenseVectors.load()
        let token = try #require(LicenseToken(try vectors.token("valid")))
        #expect(await !verifyLicenseToken(token, publicKeys: licensePublicKeys, verifier: defaultLicenseVerifier()))
    }

    @Test func theProductionKeySetVerifiesAProductionToken() async throws {
        // Granted by events.desertant.com to the test bundle.
        let token = try #require(LicenseToken("eyJhbGciOiJFUzI1NiIsImtpZCI6InByb2QtMjAyNjEwMDgiLCJ0eXAiOiJkYWwtbGljZW5zZStqd3QifQ.eyJ2IjoxLCJsaWQiOiIwNjBhYmE5YS0xMGQ0LThjN2QtODhhOC00ODUzYmIzYjNiNjQiLCJwZXJpb2QiOiIyMDI2LTEwIiwicGVyaW9kRW5kIjoiMjAyNi0xMS0wMVQwMDowMDowMFoiLCJhcHAiOiJpb3M6ZGVzZXJ0YW50cGFja2FnZXRlc3RzLnhjdGVzdCIsIm1vZGVsIjoiZW1vIiwibW9kZWxWZXJzaW9uIjoiIiwic2RrIjoiZGVzZXJ0LWFudC1jb3JlIiwic2RrVmVyc2lvbiI6IjQuMC4wIiwicGxhdGZvcm0iOiJpb3MiLCJpYXQiOjE3OTE0OTUyNjZ9.5g1zpeyhrHVicdQV97e6CxPmPJRqlkkKuNTf6i-1QaPHHa9cpX0dLMOgGlKXNdHe7IgSaxpF37JNcA1rxBLBLg"))
        #expect(await verifyLicenseToken(token, publicKeys: licensePublicKeys, verifier: defaultLicenseVerifier()))
    }

    @Test func storesTheValidVectorToken() async throws {
        let vectors = try LicenseVectors.load()
        let token = try vectors.token("valid")
        let h = LicenseHarness(verifier: defaultLicenseVerifier(), publicKeys: vectors.publicKeys)
        await h.host.queue("license", grantReply(token))

        await h.load()

        #expect(await h.host.paths == ["license"])
        #expect(h.stored.token == token)
    }

    @Test func discardsTheTamperedVectorTokens() async throws {
        let vectors = try LicenseVectors.load()
        for name in ["bad-signature", "tampered-payload", "unknown-kid"] {
            let h = LicenseHarness(verifier: defaultLicenseVerifier(), publicKeys: vectors.publicKeys)
            await h.host.queue("license", grantReply(try vectors.token(name)))

            await h.load()

            #expect(await h.host.paths == ["license"], "\(name)")
            #expect(h.stored.token == nil, "\(name)")
            #expect(h.stored.refusedAt == ["emo": serverNoon], "\(name)")
        }
    }

    @Test func aStoredTokenThatFailsVerificationIsDroppedAndGrantedAgain() async throws {
        let vectors = try LicenseVectors.load()
        let valid = try vectors.token("valid")
        let parts = valid.split(separator: ".").map(String.init)
        let payload = String(decoding: try #require(base64Decode(parts[1])), as: UTF8.self)
        let later = payload.replacingOccurrences(of: "2026-11-07T00:00:00Z", with: "2027-11-07T00:00:00Z")
        try #require(later != payload)
        var stored = try ["bad-signature", "tampered-payload", "unknown-kid", "malformed"].map { ($0, try vectors.token($0)) }
        stored.append(("later-period-end", parts[0] + "." + base64URL(Array(later.utf8)) + "." + parts[2]))

        for (name, token) in stored {
            let h = LicenseHarness(verifier: defaultLicenseVerifier(), publicKeys: vectors.publicKeys)
            h.storage.saveLicense(StoredLicense(token: token), "dal_test")
            await h.host.queue("license", grantReply(valid))

            await h.load()

            #expect(await h.host.paths == ["license"], "\(name)")
            #expect(h.stored.token == valid, "\(name)")
        }
    }

    @Test func aStoredTokenThatFailsVerificationStillWaitsOutARefusedGrant() async throws {
        let vectors = try LicenseVectors.load()
        let h = LicenseHarness(verifier: defaultLicenseVerifier(), publicKeys: vectors.publicKeys)
        let refused = serverNoon - hourMs
        let record = StoredLicense(token: try vectors.token("tampered-payload"), refusedAt: ["emo": refused])
        h.storage.saveLicense(record, "dal_test")

        await h.load()

        #expect(await h.host.paths == [])
        #expect(h.stored == record)

        await h.load("redact")
        #expect(await h.host.paths == ["license"])
        #expect(h.stored == StoredLicense(refusedAt: ["emo": refused]))
    }

    @Test func theExpiryComesFromTheSignedTokenNotTheRecord() async throws {
        let vectors = try LicenseVectors.load()
        let valid = try vectors.token("valid")
        let signed = try #require(LicenseToken(valid))
        let end = try #require(parseISO8601(signed.payload.periodEnd))
        let h = LicenseHarness(now: end - 1, verifier: defaultLicenseVerifier(), publicKeys: vectors.publicKeys)
        h.storage.set(
            licenseStorageKey("dal_test"),
            #"{"token":"\#(valid)","periodEnd":\#(end + 365 * dayMs),"activatedModels":["emo"],"serverOffset":0}"#)

        await h.load()
        #expect(await h.host.paths == [])

        h.clock.ms = end
        await h.load()
        #expect(await h.host.paths == ["license"])
        #expect(h.stored.token == nil)
    }

    @Test func anEstimatedServerTimeBeforeIatCountsAsExpired() async throws {
        let vectors = try LicenseVectors.load()
        let valid = try vectors.token("valid")
        let issued = try #require(LicenseToken(valid)).payload.iat * 1000
        let cases: [(Int64, [String])] = [
            (issued - serverNoon, []),
            (issued - serverNoon - 1, ["license"]),
            (-365 * dayMs, ["license"]),
        ]
        for (offset, paths) in cases {
            let h = LicenseHarness(verifier: defaultLicenseVerifier(), publicKeys: vectors.publicKeys)
            h.storage.saveLicense(StoredLicense(token: valid, activatedModels: ["emo"], serverOffset: offset), "dal_test")
            await h.host.queue("license", grantReply(valid))

            await h.load()

            #expect(await h.host.paths == paths, "offset \(offset)")
            #expect(h.stored.serverOffset == (paths.isEmpty ? offset : 0), "offset \(offset)")
            #expect(h.stored.token == valid, "offset \(offset)")
        }
    }
    #endif
}
#endif
