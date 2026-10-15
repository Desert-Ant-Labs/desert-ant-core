import JSON
import PlatformSupport
import Testing
@testable import Usage
#if os(WASI)
import JavaScriptKit
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class SharedStorage: UsageStorage, @unchecked Sendable {
    var values: [String: String] = [:]
    func get(_ key: String) -> String? { values[key] }
    func set(_ key: String, _ value: String) { values[key] = value }
}

final class TestClock: @unchecked Sendable {
    var ms: Int64
    init(_ ms: Int64) { self.ms = ms }
}

final class TestScheduler: @unchecked Sendable {
    var delays: [Int64] = []
    private var jobs: [@Sendable () async -> Void] = []

    func add(_ delay: Int64, _ work: @escaping @Sendable () async -> Void) {
        delays.append(delay)
        jobs.append(work)
    }

    var pending: Int { jobs.count }

    func fire() async {
        let due = jobs
        jobs = []
        for job in due { await job() }
    }
}

final class IdentityBox: @unchecked Sendable {
    var value = LicenseIdentity(appId: "com.acme.app", apiKey: "dal_test", platform: "ios")
}

struct StubVerifier: LicenseSignatureVerifier {
    let accepts: Bool
    func isValidSignature(_ signature: [UInt8], for message: [UInt8], publicKey: [UInt8]) -> Bool { accepts }
}

struct NetworkDown: Error {}

actor MockLicenseHost {
    struct Request {
        let url: String
        let body: [UInt8]
        let headers: [String: String]
        var path: String { url.hasSuffix("/license") ? "license" : url.hasSuffix("/activate") ? "activate" : url }
    }

    enum Reply {
        case response(HTTPResponse)
        case networkError
    }

    private(set) var requests: [Request] = []
    private var replies: [String: [Reply]] = [:]

    func queue(_ path: String, _ reply: Reply) { replies[path, default: []].append(reply) }

    var paths: [String] { requests.map(\.path) }

    func handle(_ url: String, _ body: [UInt8], _ headers: [String: String]) throws -> HTTPResponse {
        let request = Request(url: url, body: body, headers: headers)
        requests.append(request)
        guard var queued = replies[request.path], !queued.isEmpty else { throw NetworkDown() }
        let reply = queued.removeFirst()
        replies[request.path] = queued
        switch reply {
        case .response(let response): return response
        case .networkError: throw NetworkDown()
        }
    }
}

func base64URL(_ bytes: [UInt8]) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    var text = ""
    var index = 0
    while index < bytes.count {
        let chunk = Array(bytes[index..<min(index + 3, bytes.count)])
        var bits: UInt32 = 0
        for (offset, byte) in chunk.enumerated() { bits |= UInt32(byte) << UInt32(16 - 8 * offset) }
        for position in 0...chunk.count { text.append(alphabet[Int((bits >> UInt32(18 - 6 * position)) & 63)]) }
        index += 3
    }
    return text
}

func syntheticToken(periodEnd: String = "2026-11-01T00:00:00Z", alg: String = "ES256") -> String {
    let header = #"{"alg":"\#(alg)","kid":"test-2","typ":"dal-license+jwt"}"#
    let payload = #"{"v":1,"lid":"efe0d0d2-a957-8026-8b33-e6618d4f4dff","period":"2026-10","periodEnd":"\#(periodEnd)","app":"ios:com.acme.app","model":"emo","modelVersion":"v0.7.0","sdk":"desert-ant-core","sdkVersion":"3.6.0","platform":"ios","iat":1791331200}"#
    return base64URL(Array(header.utf8)) + "." + base64URL(Array(payload.utf8)) + "."
        + base64URL([UInt8](repeating: 7, count: 64))
}

func reply(_ status: Int, _ body: String, retryAfter: String? = nil) -> MockLicenseHost.Reply {
    .response(HTTPResponse(
        status: status, headers: retryAfter.map { [("Retry-After", $0)] } ?? [], body: Array(body.utf8)))
}

func grantReply(_ token: String, serverTime: String = "2026-10-07T12:00:00.000Z") -> MockLicenseHost.Reply {
    reply(200, #"{"token":"\#(token)","licenseId":"efe0d0d2-a957-8026-8b33-e6618d4f4dff","period":"2026-10","periodEnd":"2026-11-01T00:00:00Z","serverTime":"\#(serverTime)"}"#)
}

let activatedReply = reply(200, #"{"activated":true,"period":"2026-10","serverTime":"2026-10-07T12:00:00.000Z"}"#)
let serverNoon = parseISO8601("2026-10-07T12:00:00.000Z")!
let novemberFirst = parseISO8601("2026-11-01T00:00:00Z")!
let minuteMs: Int64 = 60 * 1000

struct LicenseHarness {
    let storage: SharedStorage
    let host: MockLicenseHost
    let clock: TestClock
    let scheduler: TestScheduler
    let identity: IdentityBox
    let client: LicenseClient

    init(
        now: Int64 = serverNoon,
        verifier: (any LicenseSignatureVerifier)? = StubVerifier(accepts: true),
        publicKeys: [String: String] = ["test-2": "BA=="],
        jitter: @escaping @Sendable (Int64) -> Int64 = { $0 }
    ) {
        let storage = SharedStorage()
        let host = MockLicenseHost()
        let clock = TestClock(now)
        let scheduler = TestScheduler()
        let identity = IdentityBox()
        self.storage = storage
        self.host = host
        self.clock = clock
        self.scheduler = scheduler
        self.identity = identity
        client = LicenseClient(
            storage: storage,
            post: { url, body, headers in try await host.handle(url, body, headers) },
            now: { clock.ms },
            schedule: { delay, work in scheduler.add(delay, work) },
            jitter: jitter,
            publicKeys: publicKeys,
            verifier: verifier,
            endpoint: { "http://license.test/api/v1/" },
            identity: { identity.value })
    }

    func load(_ model: String = "emo") async {
        await client.modelLoaded(model: model, modelVersion: "v0.7.0")
    }

    var stored: StoredLicense { storage.loadLicense("dal_test", "emo") }
}

private struct GrantBody: Decodable {
    struct SDK: Decodable {
        var name: String
        var version: String
    }

    struct App: Decodable {
        var id: String
    }

    var installId: String
    var model: String
    var modelVersion: String
    var sdk: SDK
    var platform: String
    var app: App
    var key: String?
}

private struct ActivateBody: Decodable {
    var license: String
    var key: String?
}

@Suite struct LicensingFlowTests {
    @Test func grantsThenActivatesWithTheKeyPlacedAsToday() async throws {
        let h = LicenseHarness(now: serverNoon - 5 * minuteMs)
        let token = syntheticToken()
        await h.host.queue("license", grantReply(token))
        await h.host.queue("activate", activatedReply)

        await h.load()

        let requests = await h.host.requests
        try #require(requests.map(\.path) == ["license", "activate"])
        #expect(requests[0].url == "http://license.test/api/v1/license")
        let grant = try JSONDecoder().decode(GrantBody.self, from: requests[0].body)
        #expect(grant.installId == h.storage.get("ai.desertant.usage.deviceId"))
        #expect(grant.installId.count == 36)
        #expect(grant.model == "emo")
        #expect(grant.modelVersion == "v0.7.0")
        #expect(grant.sdk.name == "desert-ant-core")
        #expect(grant.sdk.version == defaultSDKVersion)
        #expect(grant.platform == "ios")
        #expect(grant.app.id == "com.acme.app")
        let activate = try JSONDecoder().decode(ActivateBody.self, from: requests[1].body)
        #expect(activate.license == token)
        #if os(WASI)
        #expect(grant.key == "dal_test" && activate.key == "dal_test")
        #expect(requests.allSatisfy { $0.headers["Authorization"] == nil })
        #else
        #expect(grant.key == nil && activate.key == nil)
        #expect(requests.allSatisfy { $0.headers["Authorization"] == "Bearer dal_test" })
        #endif

        let stored = h.stored
        #expect(stored.token == token)
        #expect(stored.licenseId == "efe0d0d2-a957-8026-8b33-e6618d4f4dff")
        #expect(stored.period == "2026-10")
        #expect(stored.activated)
        #expect(stored.serverOffset == 5 * minuteMs)
        #expect(h.scheduler.pending == 0)
    }

    @Test func makesNoRequestWhileTheStoredTokenIsValidAndActivated() async {
        let h = LicenseHarness()
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.host.queue("activate", activatedReply)
        await h.load()

        h.clock.ms += 10 * dayMs
        await h.load()
        await h.load()

        #expect(await h.host.paths == ["license", "activate"])
        #expect(h.scheduler.pending == 0)
    }

    @available(*, deprecated)
    @Test func theRetiredSwitchDoesNotStopALicense() async {
        DesertAnt.sendsDeviceContext = false
        defer { DesertAnt.sendsDeviceContext = true }
        let h = LicenseHarness()
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.host.queue("activate", activatedReply)

        await h.load()

        #expect(await h.host.paths == ["license", "activate"])
        #expect(h.stored.activated)
    }

    @Test func aGrantSendsTheDeviceIdAnEarlierReleaseStored() async throws {
        let h = LicenseHarness()
        let earlier = "7f9c2ba4-e88f-4c6e-9b1a-3d5e8a2f6c01"
        h.storage.values["ai.desertant.usage.deviceId"] = earlier
        h.storage.values["ai.desertant.usage.dal_test.\(earlier).state"] = "1791331200000,4"
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.host.queue("activate", activatedReply)

        await h.load()

        let requests = await h.host.requests
        try #require(requests.map(\.path) == ["license", "activate"])
        #expect(try JSONDecoder().decode(GrantBody.self, from: requests[0].body).installId == earlier)
        #expect(h.storage.get("ai.desertant.usage.deviceId") == earlier)
    }

    #if os(WASI)
    @Test func aHostDeviceIdIsNotTheInstallId() async throws {
        JSObject.global.__dalDeviceId = .string("tenant-device-7")
        defer { _ = JSObject.global.Reflect.object!.deleteProperty!(JSObject.global, "__dalDeviceId") }
        let h = LicenseHarness()
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.host.queue("activate", activatedReply)

        await h.load()

        let requests = await h.host.requests
        try #require(requests.first?.path == "license")
        let installId = try JSONDecoder().decode(GrantBody.self, from: requests[0].body).installId
        #expect(installId != "tenant-device-7")
        #expect(installId == h.storage.get("ai.desertant.usage.deviceId"))
    }
    #endif

    @Test func expiryUsesTheEstimatedServerTime() async {
        let ahead = LicenseHarness(now: novemberFirst - 4 * minuteMs)
        ahead.storage.saveLicense(
            StoredLicense(token: syntheticToken(), activated: true, serverOffset: 5 * minuteMs),
            "dal_test", "emo")
        await ahead.load()
        #expect(await ahead.host.paths == ["license"])

        let atTheEnd = LicenseHarness(now: novemberFirst - 5 * minuteMs)
        atTheEnd.storage.saveLicense(
            StoredLicense(token: syntheticToken(), activated: true, serverOffset: 5 * minuteMs),
            "dal_test", "emo")
        await atTheEnd.load()
        #expect(await atTheEnd.host.paths == ["license"])

        let behind = LicenseHarness(now: novemberFirst + 4 * minuteMs)
        behind.storage.saveLicense(
            StoredLicense(token: syntheticToken(), activated: true, serverOffset: -5 * minuteMs),
            "dal_test", "emo")
        await behind.load()
        #expect(await behind.host.paths == [])
    }

    @Test func activatesAPendingTokenThatIsStillValid() async {
        let h = LicenseHarness(now: serverNoon - 3 * minuteMs)
        h.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test", "emo")
        await h.host.queue("activate", activatedReply)

        await h.load()

        #expect(await h.host.paths == ["activate"])
        #expect(h.stored.activated)
        #expect(h.stored.serverOffset == 3 * minuteMs)
    }

    @Test func activatesAnExpiredPendingTokenLateThenGrantsTheNewMonth() async {
        let h = LicenseHarness(now: novemberFirst + dayMs)
        h.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test", "emo")
        await h.host.queue("activate", activatedReply)
        await h.host.queue("license", reply(503, #"{"error":"retry"}"#))

        await h.load()

        #expect(await h.host.paths == ["activate", "license"])
        #expect(h.stored.token == nil)
        #expect(!h.stored.activated)
    }

    @Test func keepsAnExpiredPendingTokenWhileItsLateActivationFails() async {
        let h = LicenseHarness(now: novemberFirst + dayMs)
        h.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test", "emo")
        await h.host.queue("activate", reply(503, #"{"error":"retry"}"#))

        await h.load()

        #expect(await h.host.paths == ["activate"])
        #expect(h.stored.token == syntheticToken())
        #expect(!h.stored.activated)
    }

    @Test func doesNotReactivateAnExpiredActivatedToken() async {
        let h = LicenseHarness(now: novemberFirst + dayMs)
        var stored = StoredLicense(token: syntheticToken())
        stored.activated = true
        h.storage.saveLicense(stored, "dal_test", "emo")
        await h.host.queue("license", reply(503, #"{"error":"retry"}"#))

        await h.load()

        #expect(await h.host.paths == ["license"])
    }

    @Test func retriesA503InTheBackgroundHonoringRetryAfter() async {
        let h = LicenseHarness(jitter: { _ in 0 })
        await h.host.queue("license", reply(503, #"{"error":"retry"}"#, retryAfter: "60"))

        await h.load()
        #expect(await h.host.paths == ["license"])
        #expect(h.scheduler.delays == [60_000])

        await h.load()
        #expect(await h.host.paths == ["license"])

        await h.host.queue("license", grantReply(syntheticToken()))
        await h.host.queue("activate", activatedReply)
        await h.scheduler.fire()

        #expect(await h.host.paths == ["license", "license", "activate"])
        #expect(h.stored.activated)
        #expect(h.scheduler.pending == 0)
    }

    @Test func serverErrorsBackOffExponentiallyAndResetOnSuccess() async {
        let h = LicenseHarness()
        for _ in 0..<3 { await h.host.queue("license", reply(500, "oops")) }
        await h.load()
        await h.scheduler.fire()
        await h.scheduler.fire()
        #expect(h.scheduler.delays == [60_000, 120_000, 240_000])

        await h.host.queue("license", grantReply(syntheticToken()))
        await h.host.queue("activate", reply(429, #"{"error":"slow_down"}"#))
        await h.scheduler.fire()
        #expect(h.scheduler.delays.last == 480_000)

        await h.host.queue("activate", activatedReply)
        await h.scheduler.fire()
        #expect(h.stored.activated)
        #expect(await h.host.paths == ["license", "license", "license", "license", "activate", "activate"])

        h.clock.ms = novemberFirst
        await h.host.queue("license", reply(502, ""))
        await h.load()
        #expect(h.scheduler.delays.last == 60_000)
    }

    @Test func networkErrorsRetryEveryFiveMinutes() async {
        let h = LicenseHarness()
        await h.host.queue("license", .networkError)

        await h.load()
        await h.scheduler.fire()

        #expect(h.scheduler.delays == [licenseNetworkRetryMs, licenseNetworkRetryMs])
        #expect(licenseNetworkRetryMs == 5 * minuteMs)
        #expect(h.stored == StoredLicense())
    }

    @Test func aFailedActivationRetriesOnlyTheActivationAndKeepsTheToken() async {
        let h = LicenseHarness()
        let token = syntheticToken()
        await h.host.queue("license", grantReply(token))
        await h.host.queue("activate", reply(503, #"{"error":"unknown_key"}"#, retryAfter: "3600"))

        await h.load()
        #expect(h.scheduler.delays == [hourMs])
        #expect(h.stored.token == token && !h.stored.activated)

        await h.host.queue("activate", .networkError)
        await h.scheduler.fire()
        #expect(h.scheduler.delays == [hourMs, licenseNetworkRetryMs])

        await h.host.queue("activate", activatedReply)
        await h.scheduler.fire()
        #expect(await h.host.paths == ["license", "activate", "activate", "activate"])
        #expect(h.stored.token == token)
        #expect(h.stored.activated)
        #expect(h.scheduler.pending == 0)
    }

    @Test func aPendingTokenThatExpiresDuringABackoffIsActivatedLateThenReplaced() async throws {
        let h = LicenseHarness(now: novemberFirst - minuteMs)
        let october = syntheticToken()
        let november = syntheticToken(periodEnd: "2026-12-01T00:00:00Z")
        await h.host.queue("license", grantReply(october, serverTime: "2026-10-31T23:59:00.000Z"))
        await h.host.queue("activate", reply(503, #"{"error":"retry"}"#, retryAfter: "60"))
        await h.load()
        #expect(h.stored.token == october && !h.stored.activated)

        h.clock.ms += 2 * minuteMs
        await h.host.queue("activate", activatedReply)
        await h.host.queue("license", grantReply(november, serverTime: "2026-11-01T00:01:00.000Z"))
        await h.host.queue("activate", activatedReply)
        await h.scheduler.fire()

        let requests = await h.host.requests
        #expect(requests.map(\.path) == ["license", "activate", "activate", "license", "activate"])
        let activated = try requests.filter { $0.path == "activate" }
            .map { try JSONDecoder().decode(ActivateBody.self, from: $0.body).license }
        #expect(activated == [october, october, november])
        #expect(h.stored.token == november)
        #expect(h.stored.activated)
    }

    @Test(arguments: [
        (400, #"{"error":"invalid_request","message":"license"}"#),
        (422, #"{"error":"invalid_license"}"#),
    ])
    func anActivationRefusedWithADalErrorBodyDeletesTheTokenAndGrantsAgainADayLater(status: Int, body: String) async {
        let h = LicenseHarness()
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.host.queue("activate", reply(status, body))

        await h.load()

        #expect(await h.host.paths == ["license", "activate"])
        #expect(h.stored.token == nil)
        #expect(h.stored.lastFailedGrantAt == h.clock.ms)
        #expect(h.scheduler.pending == 0)

        h.clock.ms += 23 * hourMs
        await h.load()
        #expect(await h.host.paths == ["license", "activate"])

        h.clock.ms += 2 * hourMs
        await h.load()
        #expect(await h.host.paths == ["license", "activate", "license"])
    }

    @Test(arguments: [
        (400, #"{"error":"invalid_request","message":"installId"}"#),
        (422, #"{"error":"invalid_license"}"#),
    ])
    func aGrantRefusedWithADalErrorBodyWaitsADay(status: Int, body: String) async {
        let h = LicenseHarness()
        await h.host.queue("license", reply(status, body))

        await h.load()
        h.clock.ms += 23 * hourMs
        await h.load()

        #expect(await h.host.paths == ["license"])
        #expect(h.stored.lastFailedGrantAt == serverNoon)
        #expect(h.scheduler.pending == 0)

        h.clock.ms += hourMs
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.host.queue("activate", activatedReply)
        await h.load()
        #expect(await h.host.paths == ["license", "license", "activate"])
        #expect(h.stored.activated)
        #expect(h.stored.lastFailedGrantAt == nil)
    }

    @Test func a400WithoutADalErrorBodyIsRetried() async {
        let h = LicenseHarness()
        await h.host.queue("license", reply(400, "<html>Bad Request</html>"))

        await h.load()

        #expect(h.scheduler.delays == [60_000])
        #expect(h.stored.lastFailedGrantAt == nil)
    }

    @Test func aTokenThatFailsVerificationIsDiscardedAndNotActivated() async {
        let h = LicenseHarness(verifier: StubVerifier(accepts: false))
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.load()
        h.clock.ms += 12 * hourMs
        await h.load()

        #expect(await h.host.paths == ["license"])
        #expect(h.stored.token == nil)
        #expect(h.stored.lastFailedGrantAt == serverNoon)
        #expect(h.stored.serverOffset == 0)
        #expect(h.scheduler.pending == 0)

        h.clock.ms += 12 * hourMs
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.load()
        #expect(await h.host.paths == ["license", "license"])
    }

    @Test func aMalformedGrantBodyIsRetriedNotTrusted() async {
        let h = LicenseHarness()
        await h.host.queue("license", reply(200, "<html>captive portal</html>"))
        await h.host.queue("activate", reply(200, "<html>captive portal</html>"))

        await h.load()
        #expect(h.scheduler.delays == [60_000])

        await h.host.queue("license", grantReply(syntheticToken()))
        await h.scheduler.fire()
        #expect(await h.host.paths == ["license", "license", "activate"])
        #expect(!h.stored.activated)
        #expect(h.scheduler.pending == 1)
    }

    @Test func concurrentLoadsShareOneFlow() async {
        let h = LicenseHarness()
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.host.queue("activate", activatedReply)

        async let first: Void = h.load()
        async let second: Void = h.load()
        async let third: Void = h.load()
        _ = await (first, second, third)

        #expect(await h.host.paths == ["license", "activate"])
    }

    @Test func eachAppKeyAndModelHasItsOwnLicense() async {
        let h = LicenseHarness()
        for _ in 0..<2 {
            await h.host.queue("license", grantReply(syntheticToken()))
            await h.host.queue("activate", activatedReply)
        }
        await h.load("emo")
        await h.load("redact")
        #expect(await h.host.paths == ["license", "activate", "license", "activate"])
        #expect(h.storage.loadLicense("dal_test", "emo").activated)
        #expect(h.storage.loadLicense("dal_test", "redact").activated)

        h.identity.value = LicenseIdentity(appId: "com.acme.app", apiKey: nil, platform: "ios")
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.host.queue("activate", activatedReply)
        await h.load("emo")
        #expect(h.storage.loadLicense("com.acme.app", "emo").activated)
        #expect(Set(h.storage.values.keys) == [
            "ai.desertant.usage.deviceId",
            "ai.desertant.license.dal_test.emo",
            "ai.desertant.license.dal_test.redact",
            "ai.desertant.license.com.acme.app.emo",
        ])
    }

    @Test func aStoreThatDropsWritesKeepsOneInstallIdPerProcess() async throws {
        final class DroppingStorage: UsageStorage, @unchecked Sendable {
            func get(_ key: String) -> String? { nil }
            func set(_ key: String, _ value: String) {}
        }
        let host = MockLicenseHost()
        let client = LicenseClient(
            storage: DroppingStorage(),
            post: { url, body, headers in try await host.handle(url, body, headers) },
            now: { serverNoon },
            schedule: { _, _ in },
            publicKeys: ["test-2": "BA=="],
            verifier: StubVerifier(accepts: true),
            endpoint: { "http://license.test/api/v1" },
            identity: { LicenseIdentity(appId: "com.acme.app", apiKey: nil, platform: "android") })
        for _ in 0..<2 {
            await host.queue("license", grantReply(syntheticToken()))
            await host.queue("activate", activatedReply)
            await client.modelLoaded(model: "emo", modelVersion: "v0.7.0")
        }

        let grants = await host.requests.filter { $0.path == "license" }
        try #require(grants.count == 2)
        let ids = try grants.map { try JSONDecoder().decode(GrantBody.self, from: $0.body).installId }
        #expect(ids[0] == ids[1])
    }
}

@Suite struct LicenseStorageTests {
    @Test func aRecordRoundTripsThroughTheStore() {
        let store = InMemoryStorage()
        let record = StoredLicense(
            token: "a.b.c", licenseId: "lid", period: "2026-10",
            activated: true, lastFailedGrantAt: 12, serverOffset: -340)
        store.saveLicense(record, "dal_test", "emo")
        #expect(store.loadLicense("dal_test", "emo") == record)
        #expect(store.loadLicense("dal_test", "redact") == StoredLicense())
    }

    @Test func anUnreadableRecordReadsAsEmpty() {
        let store = InMemoryStorage(["ai.desertant.license.dal_test.emo": "not json"])
        #expect(store.loadLicense("dal_test", "emo") == StoredLicense())
    }

    @Test func droppingTheTokenKeepsTheOffsetAndTheFailureTime() {
        var record = StoredLicense(
            token: "a.b.c", licenseId: "lid", period: "2026-10",
            activated: true, lastFailedGrantAt: 12, serverOffset: 99)
        record.dropToken()
        #expect(record == StoredLicense(lastFailedGrantAt: 12, serverOffset: 99))
    }
}

@Suite struct LicenseHelperTests {
    @Test func backoffDoublesFromOneMinuteToSixHours() {
        let delays = (0..<12).map { licenseBackoff(attempt: $0, retryAfter: nil, jitter: { $0 }) }
        #expect(Array(delays.prefix(5)) == [60_000, 120_000, 240_000, 480_000, 960_000])
        #expect(delays.max() == licenseMaxBackoffMs)
        #expect(licenseMaxBackoffMs == 6 * hourMs)
        #expect(licenseBackoff(attempt: 1_000, retryAfter: nil, jitter: { $0 }) == licenseMaxBackoffMs)
        #expect(licenseBackoff(attempt: 3, retryAfter: nil, jitter: { _ in 0 }) == 0)
    }

    @Test func retryAfterIsAFloorCappedAtSixHours() {
        #expect(licenseBackoff(attempt: 0, retryAfter: 3_600_000, jitter: { $0 }) == 3_600_000)
        #expect(licenseBackoff(attempt: 5, retryAfter: 1_000, jitter: { $0 }) == 1_920_000)
        #expect(licenseBackoff(attempt: 0, retryAfter: 99 * hourMs, jitter: { $0 }) == licenseMaxBackoffMs)
    }

    @Test func retryAfterParsesDeltaSeconds() {
        func parse(_ value: String) -> Int64? {
            licenseRetryAfter(HTTPResponse(status: 503, headers: [("retry-after", value)], body: []))
        }
        #expect(parse("60") == 60_000)
        #expect(parse(" 3600 ") == 3_600_000)
        #expect(parse("999999999") == licenseMaxBackoffMs)
        #expect(parse("-5") == nil)
        #expect(parse("Wed, 21 Oct 2026 07:28:00 GMT") == nil)
        #expect(licenseRetryAfter(HTTPResponse(status: 503, headers: [], body: [])) == nil)
    }

    @Test func base64AcceptsBothAlphabetsAndOptionalPadding() {
        #expect(base64Decode("TWFu") == Array("Man".utf8))
        #expect(base64Decode("TWE") == Array("Ma".utf8))
        #expect(base64Decode("TWE=") == Array("Ma".utf8))
        #expect(base64Decode("TQ") == Array("M".utf8))
        #expect(base64Decode("TQ==") == Array("M".utf8))
        #expect(base64Decode("-_8") == [0xFB, 0xFF])
        #expect(base64Decode("+/8") == [0xFB, 0xFF])
        #expect(base64Decode("") == [])
        #expect(base64Decode("T") == nil)
        #expect(base64Decode("T@") == nil)
        #expect(base64Decode("TQ==TQ") == nil)
    }

    @Test func iso8601ParsesTheServerShapes() {
        #expect(parseISO8601("1970-01-01T00:00:00Z") == 0)
        #expect(parseISO8601("2024-01-02T03:04:05.678Z") == 1_704_164_645_678)
        #expect(parseISO8601("2024-02-29T00:00:00Z") == 1_709_164_800_000)
        #expect(parseISO8601("2026-10-31T23:59:59.999Z").map { iso8601(epochMs: $0) } == "2026-10-31T23:59:59.999Z")
        #expect(parseISO8601("2026-10-07T12:00:00.1234Z").map { $0 % 1000 } == 123)
        for bad in ["", "2026-10-07", "2026-10-07T12:00:00", "2026-10-07T12:00:00+01:00", "2026-13-01T00:00:00Z",
                    "2026-10-07T12:00:00.Z", "2026-10-07 12:00:00Z", "2026-1O-07T12:00:00Z"] {
            #expect(parseISO8601(bad) == nil, "\(bad)")
        }
    }

    @Test func aSyntheticTokenParses() async throws {
        let token = try #require(LicenseToken(syntheticToken()))
        #expect(token.header.kid == "test-2")
        #expect(token.payload.periodEnd == "2026-11-01T00:00:00Z")
        #expect(token.signature.count == 64)
        #expect(await verifyLicenseToken(token, publicKeys: [:], verifier: nil))
        let es384 = try #require(LicenseToken(syntheticToken(alg: "ES384")))
        #expect(await !verifyLicenseToken(es384, publicKeys: [:], verifier: nil))
        #expect(await !verifyLicenseToken(token, publicKeys: [:], verifier: StubVerifier(accepts: true)))
    }

    #if os(WASI)
    @Test func theEndpointOverrideReadsTheHostGlobal() {
        JSObject.global.__dalLicenseEndpoint = .string("http://127.0.0.1:9/global")
        defer { _ = JSObject.global.Reflect.object!.deleteProperty!(JSObject.global, "__dalLicenseEndpoint") }
        #expect(hostProvidedLicenseEndpoint() == "http://127.0.0.1:9/global")
    }
    #else
    @Test(.enabled(if: environmentVariable("DAL_LICENSE_ENDPOINT") != nil))
    func theEndpointOverrideReadsTheEnvironment() {
        #expect(hostProvidedLicenseEndpoint() == environmentVariable("DAL_LICENSE_ENDPOINT"))
    }
    #endif

    @Test func sdkInfoEncodesOnlyNameAndVersion() throws {
        let sdk = SDKInfo(name: "Emo", version: "3.6.0", model: "emo", modelVersion: "v0.7.0")
        let json = try JSONEncoder().encodeToString(sdk)
        #expect(try JSONDecoder().decode([String: String].self, from: json) == ["name": "Emo", "version": "3.6.0"])
    }
}

#if os(WASI)
private final class TimerSpy {
    var delay: Double?
    var unrefed = false
}

@Suite struct LicenseWasmSchedulerTests {
    @Test func aPendingRetryDoesNotKeepNodeAlive() {
        let spy = TimerSpy()
        let unref = JSClosure { _ in
            spy.unrefed = true
            return .undefined
        }
        let fake = JSClosure { arguments in
            spy.delay = arguments.count > 1 ? arguments[1].number : nil
            let timer = JSObject.global.Object.function!.new()
            timer.unref = unref.jsValue
            return timer.jsValue
        }
        let saved = JSObject.global.setTimeout
        JSObject.global.setTimeout = fake.jsValue
        scheduleLicenseRetry(after: licenseNetworkRetryMs) {}
        JSObject.global.setTimeout = saved

        #expect(spy.delay == Double(licenseNetworkRetryMs))
        #expect(spy.unrefed)
    }
}
#endif

enum LicenseServerFailure: String, CaseIterable, Sendable {
    case refused, serverError, unavailableWithRetryAfter, rateLimited, badRequest, unprocessable, captivePortal, forgedToken

    var response: MockLicenseHost.Reply {
        switch self {
        case .refused: .networkError
        case .serverError: reply(500, "oops")
        case .unavailableWithRetryAfter: reply(503, #"{"error":"retry"}"#, retryAfter: "3600")
        case .rateLimited: reply(429, #"{"error":"slow_down"}"#, retryAfter: "60")
        case .badRequest: reply(400, #"{"error":"invalid_request"}"#)
        case .unprocessable: reply(422, #"{"error":"invalid_license"}"#)
        case .captivePortal: reply(200, "<html>captive portal</html>")
        case .forgedToken: grantReply(syntheticToken())
        }
    }

    var retryDelays: [Int64] {
        switch self {
        case .refused: [licenseNetworkRetryMs]
        case .serverError, .rateLimited, .captivePortal: [licenseMinBackoffMs]
        case .unavailableWithRetryAfter: [hourMs]
        case .badRequest, .unprocessable, .forgedToken: []
        }
    }
}

private actor HeldRequest {
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func hold() async throws {
        if !released {
            await withCheckedContinuation {
                held.append($0)
                for watcher in watchers { watcher.resume() }
                watchers = []
            }
        }
        throw NetworkDown()
    }

    func waitUntilHeld() async {
        if !held.isEmpty { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    func release() {
        released = true
        for continuation in held { continuation.resume() }
        held = []
    }
}

private func realTransportClient(_ endpoint: String) -> (LicenseClient, SharedStorage, TestScheduler) {
    let storage = SharedStorage()
    let scheduler = TestScheduler()
    let client = LicenseClient(
        storage: storage,
        now: { serverNoon },
        schedule: { delay, work in scheduler.add(delay, work) },
        publicKeys: [:],
        verifier: nil,
        endpoint: { endpoint },
        identity: { LicenseIdentity(appId: "com.acme.app", apiKey: nil, platform: "server") })
    return (client, storage, scheduler)
}

private var runsInCI: Bool {
    #if os(WASI)
    nodeEnvironmentVariable("CI") != nil
    #else
    environmentVariable("CI") != nil
    #endif
}

#if os(WASI)
private let echoServerPort = JSObject.global.process.object?.env.object?["DAL_ECHO_PORT"].string
    .flatMap { UInt16($0) } ?? 8199
// One thread runs every suite here, so their synchronous work stretches this wait; Node's fetch gives up alone at 300 s.
private let realTransportBound: Duration = .seconds(180)
#else
// The client gives up at licenseTimeoutSeconds (10 s); the rest is slack for a
// loaded CI runner, where URLSession teardown has pushed a silent server past 16 s.
private let realTransportBound: Duration = .seconds(30)
#endif

@Suite(.serialized) struct LicenseOutageTests {
    @Test(arguments: LicenseServerFailure.allCases)
    func aFailingServerSettlesTheLoadAtOnce(_ failure: LicenseServerFailure) async {
        let h = LicenseHarness(verifier: StubVerifier(accepts: failure != .forgedToken))
        await h.host.queue("license", failure.response)

        let elapsed = await ContinuousClock().measure { await h.load() }

        #expect(elapsed < .seconds(5))
        #expect(await h.host.paths == ["license"])
        #expect(h.scheduler.delays == failure.retryDelays)
        #expect(h.stored.token == nil && !h.stored.activated)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRequestThatNeverAnswersHoldsUpNoOtherLoad() async {
        let held = HeldRequest()
        let host = MockLicenseHost()
        let storage = SharedStorage()
        let scheduler = TestScheduler()
        let client = LicenseClient(
            storage: storage,
            post: { url, body, headers in
                if (try? JSONDecoder().decode(GrantBody.self, from: body))?.model == "emo" { try await held.hold() }
                return try await host.handle(url, body, headers)
            },
            now: { serverNoon },
            schedule: { delay, work in scheduler.add(delay, work) },
            publicKeys: ["test-2": "BA=="],
            verifier: StubVerifier(accepts: true),
            endpoint: { "http://license.test/api/v1" },
            identity: { LicenseIdentity(appId: "com.acme.app", apiKey: "dal_test", platform: "ios") })
        let hung = Task { await client.modelLoaded(model: "emo", modelVersion: "v0.7.0") }
        await held.waitUntilHeld()

        let clock = ContinuousClock()
        let again = await clock.measure { await client.modelLoaded(model: "emo", modelVersion: "v0.7.0") }
        await host.queue("license", grantReply(syntheticToken()))
        await host.queue("activate", activatedReply)
        let other = await clock.measure { await client.modelLoaded(model: "redact", modelVersion: "v0.7.0") }

        #expect(again < .seconds(5))
        #expect(other < .seconds(5))
        #expect(storage.loadLicense("dal_test", "redact").activated)
        #expect(await host.paths == ["license", "activate"])
        #expect(scheduler.pending == 0)

        await held.release()
        await hung.value
        #expect(scheduler.delays == [licenseNetworkRetryMs])
        #expect(storage.loadLicense("dal_test", "emo") == StoredLicense())
    }

    @Test func aHostThatDoesNotResolveIsRetriedAsANetworkError() async {
        let (client, storage, scheduler) = realTransportClient("http://license.invalid/api/v1")

        let elapsed = await ContinuousClock().measure {
            await client.modelLoaded(model: "emo", modelVersion: "v0.7.0")
        }

        #expect(elapsed < realTransportBound)
        #expect(scheduler.delays == [licenseNetworkRetryMs])
        #expect(Array(storage.values.keys) == ["ai.desertant.usage.deviceId"])
    }

    #if os(macOS) || os(Linux) || os(WASI)
    @Test func aServerThatNeverAnswersIsDroppedAtTheLicenseTimeout() async throws {
        #if os(WASI)
        let endpoint = "http://127.0.0.1:\(echoServerPort)/silent"
        #else
        let (fd, port) = try #require(silentListener())
        defer { close(fd) }
        let endpoint = "http://127.0.0.1:\(port)/api/v1"
        #endif
        let (client, storage, scheduler) = realTransportClient(endpoint)

        let elapsed = await ContinuousClock().measure {
            await client.modelLoaded(model: "emo", modelVersion: "v0.7.0")
        }

        #expect(elapsed > .seconds(5), "the request failed before the server could stay silent")
        #expect(elapsed < realTransportBound)
        #expect(scheduler.delays == [licenseNetworkRetryMs])
        #expect(Array(storage.values.keys) == ["ai.desertant.usage.deviceId"])
    }
    #endif

    @Test(.enabled(if: runsInCI))
    func ciPointsLicensingAtALocalPort() {
        #expect(hostProvidedLicenseEndpoint()?.hasPrefix("http://127.0.0.1:") == true,
                "CI needs DAL_LICENSE_ENDPOINT on a closed local port (mise.toml, ci.yml), or every model test posts a real grant")
    }
}
