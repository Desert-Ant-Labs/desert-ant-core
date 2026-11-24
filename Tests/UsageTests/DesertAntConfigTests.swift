import PlatformSupport
import Testing
@testable import Usage
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Serialized: the configured values and the log are process-wide state.
@Suite(.serialized) struct DesertAntConfigTests {
    @Test func configureSetsTheKey() {
        DesertAnt.configure(apiKey: "dal_code")
        defer { DesertAnt.configure(apiKey: "") }
        #expect(hostProvidedApiKey() == "dal_code")
    }

    @Test func eachCallReplacesTheKey() {
        DesertAnt.configure(apiKey: "dal_code")
        DesertAnt.configure(apiKey: "dal_other")
        defer { DesertAnt.configure(apiKey: "") }
        #expect(hostProvidedApiKey() == "dal_other")
    }

    @Test func configureSetsTheDeviceIdSecretAndALaterCallWithOnlyAKeyKeepsIt() {
        DesertAnt.configure(apiKey: "dal_code", deviceIdSecret: "0123456789abcdef0123456789abcdef")
        defer {
            DesertAnt.configure(apiKey: "")
            DesertAnt.configure(deviceIdSecret: nil)
        }
        #expect(DesertAnt.configuredDeviceIdSecret == "0123456789abcdef0123456789abcdef")
        DesertAnt.configure(apiKey: "dal_other")
        #expect(hostProvidedApiKey() == "dal_other")
        #expect(DesertAnt.configuredDeviceIdSecret == "0123456789abcdef0123456789abcdef")
    }

    @Test func aBlankDeviceIdSecretIsUnsetAndSpaceAroundOneIsDropped() {
        defer {
            DesertAnt.configure(apiKey: "")
            DesertAnt.configure(deviceIdSecret: nil)
        }
        DesertAnt.configure(apiKey: "dal_code", deviceIdSecret: " \n")
        #expect(DesertAnt.configuredDeviceIdSecret == nil)
        DesertAnt.configure(apiKey: "dal_code", deviceIdSecret: "0123456789abcdef0123456789abcdef\n")
        #expect(DesertAnt.configuredDeviceIdSecret == "0123456789abcdef0123456789abcdef")
    }

    @Test func anAppThatIsNotAServerAsksForItsOwnLicenseAlsoWithASecretSet() async {
        DesertAnt.configure(deviceIdSecret: "0123456789abcdef0123456789abcdef")
        defer { DesertAnt.configure(deviceIdSecret: nil) }
        let host = MockLicenseHost()
        await host.queue("license", grantReply(syntheticToken()))
        let client = LicenseClient(
            storage: SharedStorage(),
            post: { url, body, headers in try await host.handle(url, body, headers) },
            now: { serverNoon },
            schedule: { _, _ in },
            publicKeys: ["test-2": "BA=="],
            verifier: StubVerifier(accepts: true),
            endpoint: { "http://license.test/api/v1/" },
            identity: { LicenseIdentity(appId: "com.acme.app", apiKey: nil, platform: "ios") })

        await client.modelLoaded(model: "emo", modelVersion: "v0.7.0")

        #expect(await host.paths == ["license"])
    }

    @Test func aServerAsksForNoLicenseOfItsOwnOnceConfigureSetASecret() async {
        DesertAnt.configure(apiKey: "dal_code", deviceIdSecret: "0123456789abcdef0123456789abcdef")
        defer {
            DesertAnt.configure(apiKey: "")
            DesertAnt.configure(deviceIdSecret: nil)
        }
        let host = MockLicenseHost()
        let client = LicenseClient(
            storage: SharedStorage(),
            post: { url, body, headers in try await host.handle(url, body, headers) },
            now: { serverNoon },
            schedule: { _, _ in },
            endpoint: { "http://license.test/api/v1/" },
            identity: { LicenseIdentity(appId: "acme-api", apiKey: hostProvidedApiKey(), platform: "server") })

        await client.modelLoaded(model: "emo", modelVersion: "v0.7.0")

        #expect(await host.paths == [])
    }

    @Test func anEmptyKeyIsUnset() {
        DesertAnt.configure(apiKey: " ")
        defer { DesertAnt.configure(apiKey: "") }
        #expect(hostProvidedApiKey() == nil)
    }

#if canImport(Darwin) || canImport(Glibc)
    @Test func theEnvironmentNoLongerSetsTheKey() {
        setenv("DAL_API_KEY", "dal_env", 1)
        defer { unsetenv("DAL_API_KEY") }
        #expect(hostProvidedApiKey() == nil)
    }
#endif

    @Test func unsetByDefault() {
        #expect(hostProvidedApiKey() == nil)
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
