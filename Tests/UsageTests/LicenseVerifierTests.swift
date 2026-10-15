import JSON
import Testing
@testable import Usage
#if os(WASI)
import JavaScriptKit
#else
import Dispatch
#endif

#if os(WASI)
private struct Vectors: Decodable {
    struct Key: Decodable {
        var kid: String
        var publicKeyX963: String
    }

    struct Token: Decodable {
        var name: String
        var token: String
        var expect: String
    }

    var keys: [Key]
    var tokens: [Token]

    var publicKeys: [String: String] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0.kid, $0.publicKeyX963) })
    }

    func token(_ name: String) throws -> String {
        try #require(tokens.first { $0.name == name }?.token)
    }

    static func load() throws -> Vectors {
        let source = #filePath
        let path = String(source[..<source.lastIndex(of: "/")!]) + "/Resources/license_vectors.json"
        let fs = try #require(
            JSObject.global.process.object?.getBuiltinModule?("node:fs").object, "the WASI suite runs under Node")
        let text = try #require((try? fs.throwing.readFileSync?(path, "utf8"))?.string, "\(path)")
        return try JSONDecoder().decode(Vectors.self, from: text)
    }
}

@Suite struct WebCryptoLicenseVerifierTests {
    @Test func everyVectorTokenVerifiesAsExpected() async throws {
        let vectors = try Vectors.load()
        #expect(vectors.tokens.count >= 10)
        for vector in vectors.tokens {
            var accepted = false
            if let token = LicenseToken(vector.token) {
                accepted = await verifyLicenseToken(
                    token, publicKeys: vectors.publicKeys, verifier: WebCryptoLicenseVerifier())
            }
            #expect(accepted == (vector.expect == "valid"), "\(vector.name)")
        }
    }

    @Test func malformedKeysAndSignaturesAreRejected() async throws {
        let vectors = try Vectors.load()
        let token = try #require(LicenseToken(try vectors.token("valid")))
        let encoded = try #require(vectors.publicKeys[token.header.kid])
        let key = try #require(base64Decode(encoded))
        let other = try #require(vectors.publicKeys.first { $0.key != token.header.kid }.flatMap { base64Decode($0.value) })
        let verifier = WebCryptoLicenseVerifier()
        #expect(await verifier.isValidSignature(token.signature, for: token.signingInput, publicKey: key))
        #expect(await !verifier.isValidSignature(token.signature, for: token.signingInput, publicKey: other))
        #expect(await !verifier.isValidSignature(token.signature, for: token.signingInput, publicKey: Array(key.dropFirst())))
        #expect(await !verifier.isValidSignature(token.signature, for: token.signingInput, publicKey: [0x04] + [UInt8](repeating: 1, count: 64)))
        #expect(await !verifier.isValidSignature(Array(token.signature.dropLast()), for: token.signingInput, publicKey: key))
    }

    @Test func theDefaultIsWebCryptoAndNoneWithoutSubtle() {
        #expect(defaultLicenseVerifier() is WebCryptoLicenseVerifier)
        let reflect = JSObject.global.Reflect.object!
        let saved = JSObject.global.Object.object!.getOwnPropertyDescriptor!(JSObject.global, "crypto")
        let insecure = JSObject.global.Object.function!.new()
        insecure["value"] = JSObject.global.Object.function!.new().jsValue
        insecure["configurable"] = .boolean(true)
        let replaced = reflect.defineProperty!(JSObject.global, "crypto", insecure).boolean
        let verifier = defaultLicenseVerifier()
        _ = reflect.defineProperty!(JSObject.global, "crypto", saved)
        #expect(replaced == true)
        #expect(verifier == nil)
        #expect(defaultLicenseVerifier() is WebCryptoLicenseVerifier)
    }

    @Test func grantsAndActivatesTheValidVectorToken() async throws {
        let vectors = try Vectors.load()
        let token = try vectors.token("valid")
        let h = LicenseHarness(verifier: WebCryptoLicenseVerifier(), publicKeys: vectors.publicKeys)
        await h.host.queue("license", grantReply(token))
        await h.host.queue("activate", activatedReply)

        await h.load()

        #expect(await h.host.paths == ["license", "activate"])
        #expect(h.stored.token == token)
        #expect(h.stored.activated)
    }

    @Test func discardsTheTamperedVectorTokens() async throws {
        let vectors = try Vectors.load()
        for name in ["bad-signature", "tampered-payload", "unknown-kid"] {
            let h = LicenseHarness(verifier: WebCryptoLicenseVerifier(), publicKeys: vectors.publicKeys)
            await h.host.queue("license", grantReply(try vectors.token(name)))

            await h.load()

            #expect(await h.host.paths == ["license"], "\(name)")
            #expect(h.stored.token == nil, "\(name)")
            #expect(h.stored.lastFailedGrantAt == serverNoon, "\(name)")
        }
    }
}
#else
@Suite struct HostLicenseVerifierTests {
    @Test func theHostsAnswerDecides() {
        let verified = HostLicenseVerifier(verify: { _, _, _, _, _, _ in 1 })
        let rejected = HostLicenseVerifier(verify: { _, _, _, _, _, _ in 0 })
        let unavailable = HostLicenseVerifier(verify: { _, _, _, _, _, _ in -1 })
        let unknown = HostLicenseVerifier(verify: { _, _, _, _, _, _ in 2 })
        #expect(verified.isValidSignature([1], for: [2], publicKey: [3]))
        #expect(!rejected.isValidSignature([1], for: [2], publicKey: [3]))
        #expect(!unavailable.isValidSignature([1], for: [2], publicKey: [3]))
        #expect(!unknown.isValidSignature([1], for: [2], publicKey: [3]))
    }

    @Test func theSignatureMessageAndKeyReachTheHostInOrder() {
        let verifier = HostLicenseVerifier(verify: { signature, signatureLength, message, messageLength, key, keyLength in
            guard let signature, let message, let key, signatureLength == 64, messageLength == 3, keyLength == 65
            else { return 0 }
            return signature[63] == 0xAA && message[2] == 0xBB && key[0] == 0x04 ? 1 : 0
        })
        let signature = [UInt8](repeating: 0, count: 63) + [0xAA]
        let key = [0x04] + [UInt8](repeating: 0, count: 64)
        #expect(verifier.isValidSignature(signature, for: [0, 0, 0xBB], publicKey: key))
        #expect(!verifier.isValidSignature(signature, for: [0xBB, 0, 0], publicKey: key))
        #expect(!verifier.isValidSignature(signature, for: [0, 0, 0xBB], publicKey: Array(key.dropFirst())))
    }
}

private let callEntered = DispatchSemaphore(value: 0)
private let callReleased = DispatchSemaphore(value: 0)

private final class Outcome: @unchecked Sendable {
    var verified = false
}

@Suite(.serialized) struct InstalledLicenseVerifierTests {
    @Test func removalIsRefusedWhileACallIsInFlight() {
        #expect(installHostLicenseVerifier { _, _, _, _, _, _ in
            callEntered.signal()
            callReleased.wait()
            return 0
        } == 0)
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            outcome.verified = InstalledLicenseVerifier().isValidSignature([1], for: [2], publicKey: [3])
            done.signal()
        }
        callEntered.wait()

        #expect(installHostLicenseVerifier(nil) == 1)
        #expect(InstalledLicenseVerifier.isInstalled)
        callReleased.signal()
        done.wait()

        #expect(!outcome.verified)
        #expect(installHostLicenseVerifier(nil) == 0)
        #expect(!InstalledLicenseVerifier.isInstalled)
        #expect(InstalledLicenseVerifier().isValidSignature([1], for: [2], publicKey: [3]))
    }

    #if os(Linux)
    @Test func withoutAHostCallbackTokensGoUnverified() {
        #expect(defaultLicenseVerifier() == nil)
        #expect(installHostLicenseVerifier { _, _, _, _, _, _ in 1 } == 0)
        #expect(defaultLicenseVerifier() is InstalledLicenseVerifier)
        #expect(installHostLicenseVerifier(nil) == 0)
    }
    #endif
}
#endif
