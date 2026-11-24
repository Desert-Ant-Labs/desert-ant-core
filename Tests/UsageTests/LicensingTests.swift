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
#if !os(WASI)
import Dispatch
#endif

final class SharedStorage: UsageStorage, @unchecked Sendable {
    var values: [String: String] = [:]
    var dropsWrites: Bool
    init(dropsWrites: Bool = false) { self.dropsWrites = dropsWrites }
    func get(_ key: String) -> String? { locked { values[key] } }
    func set(_ key: String, _ value: String) { locked { if !dropsWrites { values[key] = value } } }

    #if os(WASI)
    private func locked<T>(_ body: () -> T) -> T { body() }
    #else
    private let lock = DispatchSemaphore(value: 1)

    private func locked<T>(_ body: () -> T) -> T {
        lock.wait()
        defer { lock.signal() }
        return body()
    }
    #endif
}

final class TestClock: @unchecked Sendable {
    var ms: Int64
    init(_ ms: Int64) { self.ms = ms }
}

final class TestScheduler: @unchecked Sendable {
    var delays: [Int64] = []
    var canSchedule = true
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

final class SecretBox: @unchecked Sendable {
    var value: String?
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
        var path: String {
            ["license", "licenses", "activate"].first { url.hasSuffix("/" + $0) } ?? url
        }
    }

    enum Reply {
        case response(HTTPResponse)
        case networkError
    }

    private(set) var requests: [Request] = []
    private var replies: [String: [Reply]] = [:]

    func queue(_ path: String, _ reply: Reply) { replies[path, default: []].append(reply) }

    var paths: [String] { requests.map(\.path) }

    func bodies<Body: Decodable>(_ path: String, as type: Body.Type) throws -> [Body] {
        try requests.filter { $0.path == path }.map { try JSONDecoder().decode(type, from: $0.body) }
    }

    func handle(_ url: String, _ body: [UInt8], _ headers: [String: String]) throws -> HTTPResponse {
        let request = Request(url: url, body: body, headers: headers)
        requests.append(request)
        guard var queued = replies[request.path], !queued.isEmpty else {
            if request.path == "activate", case .response(let response) = activatedReply { return response }
            throw NetworkDown()
        }
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

let activatedReply = reply(200, #"{"activated":true,"period":"2026-10"}"#)
let serverNoon = parseISO8601("2026-10-07T12:00:00.000Z")!
let novemberFirst = parseISO8601("2026-11-01T00:00:00Z")!
let minuteMs: Int64 = 60 * 1000

struct LicenseHarness {
    let storage: SharedStorage
    let host: MockLicenseHost
    let clock: TestClock
    let scheduler: TestScheduler
    let identity: IdentityBox
    let secret = SecretBox()
    let client: LicenseClient

    init(
        now: Int64 = serverNoon,
        storage: SharedStorage = SharedStorage(),
        verifier: (any LicenseSignatureVerifier)? = StubVerifier(accepts: true),
        publicKeys: [String: String] = ["test-2": "BA=="],
        jitter: @escaping @Sendable (Int64) -> Int64 = { $0 }
    ) {
        let host = MockLicenseHost()
        let clock = TestClock(now)
        let scheduler = TestScheduler()
        let identity = IdentityBox()
        self.storage = storage
        self.host = host
        self.clock = clock
        self.scheduler = scheduler
        self.identity = identity
        let secret = secret
        client = LicenseClient(
            storage: storage,
            post: { url, body, headers in try await host.handle(url, body, headers) },
            now: { clock.ms },
            schedule: { delay, work in scheduler.add(delay, work) },
            canSchedule: { scheduler.canSchedule },
            jitter: jitter,
            publicKeys: publicKeys,
            verifier: verifier,
            endpoint: { "http://license.test/api/v1/" },
            identity: { identity.value },
            secret: { secret.value })
    }

    func load(_ model: String = "emo", version: String = "v0.7.0") async {
        await client.modelLoaded(model: model, modelVersion: version)
    }

    var stored: StoredLicense { storage.loadLicense("dal_test") }
}

struct ActivateBody: Decodable, Equatable {
    var license: String
    var model: String
    var modelVersion: String
    var key: String?
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

@Suite struct LicensingFlowTests {
    @Test func requestsALicenseThenActivatesItForTheNextModel() async throws {
        let h = LicenseHarness(now: serverNoon - 5 * minuteMs)
        let token = syntheticToken()
        await h.host.queue("license", grantReply(token))

        await h.load()
        await h.load("redact", version: "v1.2.0")

        let requests = await h.host.requests
        try #require(requests.map(\.path) == ["license", "activate"])
        #expect(requests[0].url == "http://license.test/api/v1/license")
        #expect(requests[1].url == "http://license.test/api/v1/activate")
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
        #expect(activate.model == "redact")
        #expect(activate.modelVersion == "v1.2.0")
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
        #expect(stored.activatedModels == ["emo", "redact"])
        #expect(stored.serverOffset == 5 * minuteMs)
        #expect(h.scheduler.pending == 0)
    }

    @Test func makesNoRequestOnceTheLicenseIsActivatedForTheModel() async {
        let h = LicenseHarness()
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.load()

        h.clock.ms += 10 * dayMs
        await h.load()
        await h.load()

        #expect(await h.host.paths == ["license"])
        #expect(h.scheduler.pending == 0)
    }

    @available(*, deprecated)
    @Test func theRetiredSwitchDoesNotStopALicense() async {
        DesertAnt.sendsDeviceContext = false
        defer { DesertAnt.sendsDeviceContext = true }
        let h = LicenseHarness()
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.load()

        #expect(await h.host.paths == ["license"])
        #expect(h.stored.token == syntheticToken())
    }

    @Test func aGrantSendsTheDeviceIdAnEarlierReleaseStored() async throws {
        let h = LicenseHarness()
        let earlier = "7f9c2ba4-e88f-4c6e-9b1a-3d5e8a2f6c01"
        h.storage.values["ai.desertant.usage.deviceId"] = earlier
        h.storage.values["ai.desertant.usage.dal_test.\(earlier).state"] = "1791331200000,4"
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.load()

        let requests = await h.host.requests
        try #require(requests.map(\.path) == ["license"])
        #expect(try JSONDecoder().decode(GrantBody.self, from: requests[0].body).installId == earlier)
        #expect(h.storage.get("ai.desertant.usage.deviceId") == earlier)
    }

    @Test func aLicenseRequestSendsTheInstallIdThatIsStored() async throws {
        let h = LicenseHarness()
        for _ in 0..<2 { await h.host.queue("license", reply(503, #"{"error":"retry"}"#)) }
        await h.load()
        let other = "7f9c2ba4-e88f-4c6e-9b1a-3d5e8a2f6c01"
        h.storage.set("ai.desertant.usage.deviceId", other)
        await h.scheduler.fire()

        let sent = try await h.host.bodies("license", as: GrantBody.self).map(\.installId)
        try #require(sent.count == 2)
        #expect(sent[0] != other)
        #expect(sent[1] == other)
    }

    @Test func expiryUsesTheEstimatedServerTime() async {
        let ahead = LicenseHarness(now: novemberFirst - 4 * minuteMs)
        ahead.storage.saveLicense(
            StoredLicense(token: syntheticToken(), activatedModels: ["emo"], serverOffset: 5 * minuteMs),
            "dal_test")
        await ahead.load()
        #expect(await ahead.host.paths == ["license"])
        #expect(ahead.stored.token == nil)

        let atTheEnd = LicenseHarness(now: novemberFirst - 5 * minuteMs)
        atTheEnd.storage.saveLicense(
            StoredLicense(token: syntheticToken(), activatedModels: ["emo"], serverOffset: 5 * minuteMs),
            "dal_test")
        await atTheEnd.load()
        #expect(await atTheEnd.host.paths == ["license"])

        let behind = LicenseHarness(now: novemberFirst + 4 * minuteMs)
        behind.storage.saveLicense(
            StoredLicense(token: syntheticToken(), activatedModels: ["emo"], serverOffset: -5 * minuteMs),
            "dal_test")
        await behind.load()
        #expect(await behind.host.paths == [])
    }

    @Test func aLicenseExpiresAtTheSecondTheServerGives() async {
        let end = parseISO8601("2026-11-27T14:03:22Z")!
        let h = LicenseHarness(now: end - 1)
        let first = syntheticToken(periodEnd: "2026-11-27T14:03:22Z")
        let next = syntheticToken(periodEnd: "2026-12-27T14:03:22Z")
        h.storage.saveLicense(StoredLicense(token: first, activatedModels: ["emo"]), "dal_test")

        await h.load()
        #expect(await h.host.paths == [])

        h.clock.ms = end
        await h.host.queue("license", grantReply(next, serverTime: "2026-11-27T14:03:22Z"))
        await h.load()
        #expect(await h.host.paths == ["license"])
        #expect(h.stored.token == next)

        h.clock.ms = parseISO8601("2026-12-27T14:03:21Z")! + 999
        await h.load()
        #expect(await h.host.paths == ["license"])

        h.clock.ms += 1
        await h.load()
        #expect(await h.host.paths == ["license", "license"])
    }

    @Test func dropsAnExpiredTokenAndRequestsTheNextLicense() async {
        let h = LicenseHarness(now: novemberFirst + dayMs)
        h.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test")
        await h.host.queue("license", reply(503, #"{"error":"retry"}"#))

        await h.load()

        #expect(await h.host.paths == ["license"])
        #expect(h.stored.token == nil)
    }

    @Test func retriesA503InTheBackgroundHonoringRetryAfter() async {
        let h = LicenseHarness(jitter: { _ in 0 })
        await h.host.queue("license", reply(503, #"{"error":"retry"}"#, retryAfter: "60"))

        await h.load()
        #expect(await h.host.paths == ["license"])
        #expect(h.scheduler.delays == [60_000])

        await h.load("redact")
        #expect(await h.host.paths == ["license"])

        await h.host.queue("license", grantReply(syntheticToken()))
        await h.scheduler.fire()

        #expect(await h.host.paths == ["license", "license", "activate"])
        #expect(h.stored.token == syntheticToken())
        #expect(h.stored.activatedModels == ["emo", "redact"])
        #expect(h.scheduler.pending == 0)
    }

    @Test func serverErrorsBackOffExponentiallyAndResetOnSuccess() async {
        let h = LicenseHarness()
        for _ in 0..<3 { await h.host.queue("license", reply(500, "oops")) }
        await h.load()
        await h.scheduler.fire()
        await h.scheduler.fire()
        #expect(h.scheduler.delays == [60_000, 120_000, 240_000])

        await h.host.queue("license", reply(429, #"{"error":"slow_down"}"#))
        await h.scheduler.fire()
        #expect(h.scheduler.delays.last == 480_000)

        await h.host.queue("license", reply(429, #"{"error":"slow_down"}"#, retryAfter: "3600"))
        await h.scheduler.fire()
        #expect(h.scheduler.delays.last == hourMs)

        await h.host.queue("license", grantReply(syntheticToken()))
        await h.scheduler.fire()
        #expect(h.stored.token == syntheticToken())
        #expect(await h.host.paths == [String](repeating: "license", count: 6))
        #expect(h.scheduler.pending == 0)

        h.clock.ms = novemberFirst
        await h.host.queue("license", reply(502, ""))
        await h.load()
        #expect(h.scheduler.delays.last == 60_000)
    }

    @Test func aRetrySendsTheModelOfTheLoadThatStartedIt() async throws {
        let h = LicenseHarness()
        await h.host.queue("license", reply(503, #"{"error":"retry"}"#))
        await h.load("redact", version: "v1.2.0")
        await h.load("emo")

        await h.host.queue("license", grantReply(syntheticToken()))
        await h.scheduler.fire()

        let requests = await h.host.requests.filter { $0.path == "license" }
        try #require(requests.count == 2)
        let retried = try JSONDecoder().decode(GrantBody.self, from: requests[1].body)
        #expect(retried.model == "redact")
        #expect(retried.modelVersion == "v1.2.0")
    }

    @Test func aRefusalForOneModelDoesNotStopAnotherModel() async throws {
        let h = LicenseHarness()
        await h.host.queue("license", reply(422, #"{"error":"invalid_request","message":"model"}"#))
        await h.load("emo")
        #expect(h.stored.refusedAt == ["emo": serverNoon])

        h.clock.ms += 1000
        await h.load("emo")
        #expect(await h.host.requests.count == 1)

        await h.host.queue("license", grantReply(syntheticToken()))
        await h.load("redact")
        let requests = await h.host.requests.filter { $0.path == "license" }
        try #require(requests.count == 2)
        #expect(try JSONDecoder().decode(GrantBody.self, from: requests[1].body).model == "redact")
        #expect(h.stored.token == syntheticToken())
        #expect(h.stored.refusedAt == ["emo": serverNoon])
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
        #expect(h.stored.refusedAt == ["emo": serverNoon])
        #expect(h.scheduler.pending == 0)

        h.clock.ms += hourMs
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.load()
        #expect(await h.host.paths == ["license", "license"])
        #expect(h.stored.token == syntheticToken())
        #expect(h.stored.refusedAt == nil)
    }

    @Test func a400WithoutADalErrorBodyIsRetried() async {
        let h = LicenseHarness()
        await h.host.queue("license", reply(400, "<html>Bad Request</html>"))

        await h.load()

        #expect(h.scheduler.delays == [60_000])
        #expect(h.stored.refusedAt == nil)
    }

    @Test func aTokenThatFailsVerificationIsDiscarded() async {
        let h = LicenseHarness(now: serverNoon - 5 * minuteMs, verifier: StubVerifier(accepts: false))
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.load()
        h.clock.ms += 12 * hourMs
        await h.load()

        #expect(await h.host.paths == ["license"])
        #expect(h.stored.token == nil)
        #expect(h.stored.serverOffset == 0)
        #expect(h.scheduler.pending == 0)

        h.clock.ms += 12 * hourMs
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.load()
        #expect(await h.host.paths == ["license", "license"])
    }

    @Test func aClockSetBackEndsTheWait() async {
        let h = LicenseHarness()
        for _ in 0..<2 { await h.host.queue("license", reply(422, #"{"error":"invalid_request","message":"model"}"#)) }
        await h.load()
        await h.load()
        #expect(await h.host.paths == ["license"])

        h.clock.ms -= hourMs
        await h.load()
        #expect(await h.host.paths == ["license", "license"])
    }

    @Test func twoRefusedModelsEachWaitTheirOwnDay() async {
        let h = LicenseHarness()
        for _ in 0..<4 { await h.host.queue("license", reply(422, #"{"error":"invalid_request","message":"model"}"#)) }

        for _ in 0..<5 {
            await h.load("emo")
            await h.load("redact")
            h.clock.ms += 1000
        }
        #expect(await h.host.paths == ["license", "license"])

        h.clock.ms += dayMs
        await h.load("emo")
        await h.load("redact")
        await h.load("emo")
        #expect(await h.host.paths == ["license", "license", "license", "license"])
        #expect(h.scheduler.pending == 0)
    }

    @Test func aGrantedTokenThatIsNotValidOnArrivalWaitsADay() async {
        let h = LicenseHarness(now: novemberFirst + dayMs)
        for _ in 0..<3 { await h.host.queue("license", grantReply(syntheticToken(), serverTime: "2026-11-02T00:00:00Z")) }

        for _ in 0..<3 {
            await h.load()
            h.clock.ms += 1000
        }
        #expect(await h.host.paths == ["license"])
        #expect(h.stored.token == nil)
        #expect(h.scheduler.pending == 0)

        h.clock.ms += dayMs
        await h.load()
        #expect(await h.host.paths == ["license", "license"])
    }

    @Test func aBadRequestOnActivationMakesOnlyThatModelWait() async {
        let h = LicenseHarness()
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.load("emo")
        await h.host.queue("activate", reply(400, #"{"error":"invalid_request","message":"model"}"#))

        await h.load("redact")
        #expect(await h.host.paths == ["license", "activate"])
        #expect(h.stored.token == syntheticToken())
        #expect(h.stored.activatedModels == ["emo"])

        h.clock.ms += 1000
        await h.load("redact")
        await h.load("emo")
        #expect(await h.host.paths == ["license", "activate"])

        await h.load("shapes")
        #expect(await h.host.paths == ["license", "activate", "activate"])
        #expect(h.stored.activatedModels == ["emo", "shapes"])

        h.clock.ms += dayMs
        await h.load("redact")
        #expect(await h.host.paths == ["license", "activate", "activate", "activate"])
        #expect(h.stored.activatedModels == ["emo", "shapes", "redact"])
    }

    @Test func aModelRefusedOnActivationStillWaitsAfterAnotherModelGetsALicense() async {
        let h = LicenseHarness()
        h.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test")
        await h.host.queue("activate", reply(422, #"{"error":"invalid_license"}"#))
        await h.load("emo")
        #expect(await h.host.paths == ["activate"])
        #expect(h.stored.token == nil)

        h.clock.ms += 1000
        await h.load("emo")
        #expect(await h.host.paths == ["activate"])

        await h.host.queue("license", grantReply(syntheticToken()))
        await h.load("redact")
        #expect(await h.host.paths == ["activate", "license"])
        #expect(h.stored.activatedModels == ["redact"])

        await h.load("emo")
        #expect(await h.host.paths == ["activate", "license"])

        h.clock.ms += dayMs
        await h.load("emo")
        #expect(await h.host.paths == ["activate", "license", "activate"])
        #expect(h.stored.activatedModels == ["redact", "emo"])
    }

    @Test func aFailedActivationWithRetryAfterIsRetriedNoEarlier() async {
        let h = LicenseHarness(jitter: { _ in 0 })
        h.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test")
        await h.host.queue("activate", reply(503, #"{"error":"retry"}"#, retryAfter: "3600"))
        await h.load()
        #expect(await h.host.paths == ["activate"])
        #expect(h.scheduler.delays == [hourMs])

        await h.load()
        await h.load("redact")
        #expect(await h.host.paths == ["activate"])
        #expect(h.scheduler.pending == 1)

        await h.scheduler.fire()
        #expect(await h.host.paths == ["activate", "activate", "activate"])
        #expect(h.stored.activatedModels == ["emo", "redact"])
        #expect(h.scheduler.pending == 0)
    }

    @Test func aHostThatCannotSetATimerAsksAgainOnTheNextLoad() async {
        let h = LicenseHarness()
        h.scheduler.canSchedule = false
        await h.host.queue("license", reply(503, #"{"error":"retry"}"#))
        await h.load()
        #expect(await h.host.paths == ["license"])
        #expect(h.scheduler.pending == 0)

        await h.host.queue("license", grantReply(syntheticToken()))
        await h.load("redact")
        #expect(await h.host.paths == ["license", "license", "activate"])
        #expect(h.stored.activatedModels == ["emo", "redact"])
    }

    @Test func aSuccessForOneModelResetsTheBackoffForTheNext() async {
        let h = LicenseHarness()
        h.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test")
        for _ in 0..<2 { await h.host.queue("activate", reply(503, #"{"error":"retry"}"#)) }
        await h.load("emo")
        await h.load("redact")
        await h.scheduler.fire()
        #expect(h.scheduler.delays == [60_000, 120_000])

        await h.host.queue("activate", activatedReply)
        await h.host.queue("activate", reply(503, #"{"error":"retry"}"#))
        await h.scheduler.fire()
        #expect(h.stored.activatedModels == ["emo"])
        #expect(h.scheduler.delays == [60_000, 120_000, 60_000])
    }

    @Test(arguments: [false, true])
    func theBackoffGrowsWhileAModelInFrontSettlesWithoutARequest(refused: Bool) async {
        let h = LicenseHarness()
        h.storage.saveLicense(StoredLicense(token: syntheticToken(), activatedModels: refused ? nil : ["emo"]), "dal_test")
        if refused {
            await h.host.queue("activate", reply(400, #"{"error":"invalid_request","message":"model"}"#))
            await h.load("emo")
        }
        for _ in 0..<10 { await h.host.queue("activate", reply(503, #"{"error":"retry"}"#)) }

        await h.load("redact")
        for _ in 0..<9 {
            await h.load("emo")
            await h.load("redact")
            await h.scheduler.fire()
            // On WebAssembly these awaits nest on one stack until the task yields.
            await Task.yield()
        }

        #expect(h.scheduler.delays == (0..<10).map { min(licenseMaxBackoffMs, licenseMinBackoffMs << Int64($0)) })
        #expect(h.scheduler.delays.last == licenseMaxBackoffMs)
        #expect(await h.host.paths.count == (refused ? 11 : 10))
    }

    @Test func aRefusalDoesNotResetTheBackoff() async throws {
        let h = LicenseHarness()
        h.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test")
        await h.host.queue("activate", reply(503, #"{"error":"retry"}"#))
        await h.host.queue("activate", reply(400, #"{"error":"invalid_request","message":"model"}"#))
        await h.host.queue("activate", reply(503, #"{"error":"retry"}"#))

        await h.load("redact")
        await h.load("emo")
        await h.load("redact")
        await h.scheduler.fire()

        #expect(try await h.host.bodies("activate", as: ActivateBody.self).map(\.model) == ["redact", "emo", "redact"])
        #expect(h.stored.refusedAt == ["emo": serverNoon])
        #expect(h.scheduler.delays == [60_000, 120_000])
    }

    @Test func aRetryFollowsTheAppToANewKeyWithAFreshBackoff() async throws {
        let h = LicenseHarness()
        for _ in 0..<2 { await h.host.queue("license", reply(503, #"{"error":"retry"}"#)) }
        await h.load()
        await h.scheduler.fire()
        #expect(h.scheduler.delays == [60_000, 120_000])

        h.identity.value = LicenseIdentity(appId: "com.acme.app", apiKey: nil, platform: "ios")
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.scheduler.fire()
        #expect(await h.host.paths == ["license", "license", "license"])
        #expect(h.storage.loadLicense("com.acme.app").activatedModels == ["emo"])
        #expect(h.scheduler.pending == 0)

        h.identity.value = IdentityBox().value
        await h.host.queue("license", reply(503, #"{"error":"retry"}"#))
        await h.load()
        #expect(h.scheduler.delays == [60_000, 120_000, 60_000])
    }

    @Test func aModelThatWaitsLeavesTheStoredTokenAlone() async {
        let h = LicenseHarness(verifier: StubVerifier(accepts: false))
        let record = StoredLicense(token: syntheticToken(), refusedAt: ["emo": serverNoon - hourMs])
        h.storage.saveLicense(record, "dal_test")

        await h.load("emo")
        await h.load("emo")

        #expect(await h.host.paths == [])
        #expect(h.stored == record)
    }

    @Test func anActivationRefreshesTheServerClockOffset() async {
        let h = LicenseHarness(now: serverNoon - 3 * minuteMs)
        h.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test")
        await h.host.queue(
            "activate", reply(200, #"{"activated":true,"period":"2026-10","serverTime":"2026-10-07T12:00:00.000Z"}"#))

        await h.load()

        #expect(await h.host.paths == ["activate"])
        #expect(h.stored.serverOffset == 3 * minuteMs)
    }

    @Test func aMalformedGrantBodyIsRetriedNotTrusted() async {
        let h = LicenseHarness()
        await h.host.queue("license", reply(200, "<html>captive portal</html>"))

        await h.load()
        #expect(h.scheduler.delays == [60_000])

        await h.host.queue("license", grantReply(syntheticToken()))
        await h.scheduler.fire()
        #expect(await h.host.paths == ["license", "license"])
        #expect(h.stored.token == syntheticToken())
        #expect(h.scheduler.pending == 0)
    }

    @Test func modelsThatLoadTogetherShareOneGrantAndTheOthersActivate() async throws {
        let h = LicenseHarness()
        await h.host.queue("license", grantReply(syntheticToken()))

        async let first: Void = h.load("emo")
        async let second: Void = h.load("redact")
        async let third: Void = h.load("shapes")
        async let fourth: Void = h.load("emo")
        _ = await (first, second, third, fourth)

        #expect(await h.host.paths == ["license", "activate", "activate"])
        let asked = try #require(try await h.host.bodies("license", as: GrantBody.self).first?.model)
        let activations = try await h.host.bodies("activate", as: ActivateBody.self)
        #expect(Set(activations.map(\.model) + [asked]) == ["emo", "redact", "shapes"])
        #expect(activations.allSatisfy { $0.license == syntheticToken() })
        #expect(Set(h.stored.activatedModels ?? []) == ["emo", "redact", "shapes"])
    }

    @Test func modelsThatLoadTogetherUnderALicenseOnlyActivate() async throws {
        let h = LicenseHarness()
        h.storage.saveLicense(StoredLicense(token: syntheticToken(), activatedModels: ["shapes"]), "dal_test")

        async let first: Void = h.load("emo")
        async let second: Void = h.load("redact")
        _ = await (first, second)

        #expect(await h.host.paths == ["activate", "activate"])
        #expect(Set(h.stored.activatedModels ?? []) == ["shapes", "emo", "redact"])

        await h.load("emo")
        await h.load("redact")
        await h.load("shapes")
        #expect(await h.host.paths == ["activate", "activate"])
    }

    @Test(arguments: [
        (MockLicenseHost.Reply.networkError, licenseNetworkRetryMs),
        (reply(503, #"{"error":"retry"}"#), licenseMinBackoffMs),
        (reply(200, "<html>captive portal</html>"), licenseMinBackoffMs),
    ])
    func aFailedActivationIsRetriedWithoutAnotherLoad(_ failure: MockLicenseHost.Reply, delay: Int64) async {
        let h = LicenseHarness()
        h.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test")
        await h.host.queue("activate", failure)

        await h.load()
        #expect(await h.host.paths == ["activate"])
        #expect(h.stored.token == syntheticToken())
        #expect(h.stored.activatedModels == nil)
        #expect(h.scheduler.delays == [delay])

        await h.scheduler.fire()
        #expect(await h.host.paths == ["activate", "activate"])
        #expect(h.stored.activatedModels == ["emo"])
        #expect(h.scheduler.pending == 0)
    }

    @Test func anActivationAnsweredAsNotActivatedIsRetried() async {
        let h = LicenseHarness()
        h.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test")
        await h.host.queue("activate", reply(200, #"{"activated":false}"#))

        await h.load()

        #expect(await h.host.paths == ["activate"])
        #expect(h.stored.activatedModels == nil)
        #expect(h.scheduler.delays == [licenseMinBackoffMs])
    }

    @Test func anActivationRefusedAsAnInvalidLicenseDeletesTheTokenAndGrantsAgainADayLater() async {
        let h = LicenseHarness()
        h.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test")
        await h.host.queue("activate", reply(422, #"{"error":"invalid_license"}"#))

        await h.load()

        #expect(await h.host.paths == ["activate"])
        #expect(h.stored.token == nil)
        #expect(h.stored.refusedAt == ["emo": h.clock.ms])
        #expect(h.scheduler.pending == 0)

        h.clock.ms += 23 * hourMs
        await h.load()
        #expect(await h.host.paths == ["activate"])

        h.clock.ms += 2 * hourMs
        await h.load()
        #expect(await h.host.paths == ["activate", "license"])
    }

    @Test func aTokenThatFailsVerificationForOneModelDoesNotStopAnotherModel() async {
        let h = LicenseHarness()
        await h.host.queue("license", grantReply(syntheticToken(alg: "ES384")))
        await h.load("emo")
        #expect(h.stored.token == nil)

        h.clock.ms += 1000
        await h.load("emo")
        #expect(await h.host.paths == ["license"])

        await h.host.queue("license", grantReply(syntheticToken()))
        await h.load("redact")
        #expect(await h.host.paths == ["license", "license"])
        #expect(h.stored.token == syntheticToken())

        await h.load("emo")
        #expect(await h.host.paths == ["license", "license"])

        h.clock.ms += dayMs
        await h.load("emo")
        #expect(await h.host.paths == ["license", "license", "activate"])
        #expect(h.stored.activatedModels == ["redact", "emo"])
    }

    @Test func aNewLicenseStartsWithOnlyTheModelThatRequestedIt() async {
        let h = LicenseHarness(now: novemberFirst)
        h.storage.saveLicense(StoredLicense(token: syntheticToken(), activatedModels: ["emo", "redact"]), "dal_test")
        let next = syntheticToken(periodEnd: "2026-12-01T00:00:00Z")
        await h.host.queue("license", grantReply(next, serverTime: "2026-11-01T00:00:00Z"))

        await h.load("emo")

        #expect(await h.host.paths == ["license"])
        #expect(h.stored.token == next)
        #expect(h.stored.activatedModels == ["emo"])

        await h.load("redact")
        #expect(await h.host.paths == ["license", "activate"])
        #expect(h.stored.activatedModels == ["emo", "redact"])
    }

    @Test func aRefusedGrantForTheFirstModelLetsAWaitingModelAsk() async throws {
        let h = LicenseHarness()
        await h.host.queue("license", reply(422, #"{"error":"invalid_request","message":"model"}"#))
        await h.host.queue("license", grantReply(syntheticToken()))

        async let first: Void = h.load("emo")
        async let second: Void = h.load("redact")
        _ = await (first, second)

        let asked = try await h.host.bodies("license", as: GrantBody.self).map(\.model)
        #expect(Set(asked) == ["emo", "redact"])
        #expect(await h.host.paths == ["license", "license"])
        #expect(h.stored.token == syntheticToken())
        #expect(h.stored.activatedModels?.count == 1)
    }

    @Test func everyModelUsesTheOneLicenseOfItsKeyOrApp() async {
        let h = LicenseHarness()
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.load("emo")
        await h.load("redact")
        #expect(await h.host.paths == ["license", "activate"])

        h.identity.value = LicenseIdentity(appId: "com.acme.app", apiKey: nil, platform: "ios")
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.load("redact")
        await h.load("emo")
        #expect(await h.host.paths.filter { $0 == "license" }.count == 2)
        #expect(await h.host.paths.count == 4)
        #expect(Set(h.storage.values.keys) == [
            "ai.desertant.usage.deviceId",
            "ai.desertant.license.dal_test",
            "ai.desertant.license.com.acme.app",
        ])
    }

    @Test func aRecordStoredForOneModelIsNotRead() async {
        let h = LicenseHarness()
        h.storage.values["ai.desertant.license.dal_test.emo"] = #"{"token":"\#(syntheticToken())","activated":true,"serverOffset":0}"#
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.load()

        #expect(await h.host.paths == ["license"])
    }

    @Test func aStoreThatDropsWritesKeepsOneInstallIdPerProcess() async throws {
        let h = LicenseHarness(storage: SharedStorage(dropsWrites: true))
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.load()
        h.clock.ms = novemberFirst
        await h.host.queue("license", grantReply(syntheticToken(periodEnd: "2026-12-01T00:00:00Z")))
        await h.load()

        let grants = try await h.host.bodies("license", as: GrantBody.self)
        try #require(grants.count == 2)
        #expect(grants[0].installId == grants[1].installId)
    }

    @Test func aStoreThatDropsWritesGetsOneLicensePerProcess() async throws {
        let h = LicenseHarness(storage: SharedStorage(dropsWrites: true))
        for _ in 0..<3 { await h.host.queue("license", grantReply(syntheticToken())) }

        await h.load("emo")
        await h.load("redact")
        await h.load("emo")
        await h.load("redact")

        #expect(await h.host.paths == ["license", "activate"])
        #expect(try await h.host.bodies("activate", as: ActivateBody.self).map(\.model) == ["redact"])
    }

    @Test func aStoreThatStartsToDropWritesKeepsTheChangesInMemory() async throws {
        let h = LicenseHarness()
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.load("emo")
        h.storage.dropsWrites = true

        await h.load("redact")
        await h.load("redact")

        #expect(await h.host.paths == ["license", "activate"])
        #expect(h.stored.activatedModels == ["emo"])
    }

    @Test func theModelThatGetsTheLicenseSendsNoActivation() async throws {
        let h = LicenseHarness()
        await h.host.queue("license", reply(503, #"{"error":"retry"}"#))
        await h.load("emo")
        await h.load("redact")
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.scheduler.fire()

        #expect(await h.host.paths == ["license", "license", "activate"])
        #expect(try await h.host.bodies("license", as: GrantBody.self).map(\.model) == ["emo", "emo"])
        #expect(try await h.host.bodies("activate", as: ActivateBody.self).map(\.model) == ["redact"])
        #expect(h.stored.activatedModels == ["emo", "redact"])

        await h.load("shapes")
        await h.load("emo")
        #expect(try await h.host.bodies("activate", as: ActivateBody.self).map(\.model) == ["redact", "shapes"])
        #expect(await h.host.paths.filter { $0 == "license" }.count == 2)
    }

    @Test func endedWaitsLeaveTheRecordOnTheNextSave() async {
        let h = LicenseHarness()
        h.storage.saveLicense(
            StoredLicense(refusedAt: ["old": serverNoon - 25 * hourMs, "recent": serverNoon - hourMs]), "dal_test")
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.load("emo")

        #expect(h.stored.token == syntheticToken())
        #expect(h.stored.refusedAt == ["recent": serverNoon - hourMs])
    }

    @Test func aRecordWithoutAServerOffsetIsRead() async {
        let h = LicenseHarness()
        h.storage.set(licenseStorageKey("dal_test"), #"{"token":"\#(syntheticToken())","activatedModels":["emo"]}"#)

        await h.load()

        #expect(await h.host.paths == [])
        #expect(h.stored.token == syntheticToken())
    }

    @Test func aServerWithADeviceIdSecretAsksForNoLicenseOfItsOwn() async {
        let h = LicenseHarness()
        h.identity.value.platform = "server"
        h.secret.value = "0123456789abcdef0123456789abcdef"

        await h.load()
        await h.load("redact", version: "v1.2.0")

        #expect(await h.host.paths == [])
        #expect(h.scheduler.pending == 0)
        #expect(h.stored == StoredLicense())
    }

    @Test func aServerWithoutADeviceIdSecretAsksForItsOwnLicense() async throws {
        let h = LicenseHarness()
        h.identity.value.platform = "server"
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.load()

        #expect(await h.host.paths == ["license"])
        let grant = try JSONDecoder().decode(GrantBody.self, from: await h.host.requests[0].body)
        #expect(grant.platform == "server")
        #expect(grant.installId == h.storage.get("ai.desertant.usage.deviceId"))
    }

    @Test func aSecretSetWhileTheServersOwnRequestWaitsForARetryDropsTheRequest() async {
        let h = LicenseHarness()
        h.identity.value.platform = "server"
        await h.host.queue("license", .networkError)
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.load()
        #expect(h.scheduler.delays == [licenseNetworkRetryMs])
        h.secret.value = "0123456789abcdef0123456789abcdef"
        await h.scheduler.fire()
        await h.load()

        #expect(await h.host.paths == ["license"])
        #expect(h.scheduler.pending == 0)
    }
}

@Suite struct LicenseStorageTests {
    @Test func aRecordRoundTripsThroughTheStore() {
        let store = InMemoryStorage()
        let record = StoredLicense(
            token: "a.b.c", licenseId: "lid", period: "2026-10", activatedModels: ["emo"],
            refusedAt: ["redact": 12], serverOffset: -340)
        store.saveLicense(record, "dal_test")
        #expect(store.loadLicense("dal_test") == record)
        #expect(store.loadLicense("dal_other") == StoredLicense())
    }

    @Test func anUnreadableRecordReadsAsEmpty() {
        let store = InMemoryStorage(["ai.desertant.license.dal_test": "not json"])
        #expect(store.loadLicense("dal_test") == StoredLicense())
    }

    @Test func droppingTheTokenKeepsTheOffsetAndTheRefusals() {
        var record = StoredLicense(
            token: "a.b.c", licenseId: "lid", period: "2026-10", activatedModels: ["emo"],
            refusedAt: ["redact": 12], serverOffset: 99)
        record.dropToken()
        #expect(record == StoredLicense(refusedAt: ["redact": 12], serverOffset: 99))
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
        #expect(parseISO8601("2026-11-27T14:03:22Z") == 1_795_788_202_000)
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

    @Test func underNodeTheAppIdReadsTheEnvironmentFirstAsTheNativeEntryDoes() throws {
        let env = try #require(JSObject.global.process.object?.env.object)
        let before = env.DAL_APP_ID
        defer { env.DAL_APP_ID = before }
        _ = JSObject.global.Reflect.object!.deleteProperty!(env, "DAL_APP_ID")
        JSObject.global.__dalAppId = .string("acme-global")
        defer { _ = JSObject.global.Reflect.object!.deleteProperty!(JSObject.global, "__dalAppId") }
        #expect(hostProvidedAppId() == "acme-global")

        env.DAL_APP_ID = .string("acme-api")
        #expect(hostProvidedAppId() == "acme-api")
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

private struct GatedVerifier: LicenseSignatureVerifier {
    let held: HeldRequest

    func isValidSignature(_ signature: [UInt8], for message: [UInt8], publicKey: [UInt8]) async -> Bool {
        try? await held.hold()
        return true
    }
}

private func heldClient(
    _ storage: SharedStorage, _ held: HeldRequest, _ host: MockLicenseHost, _ scheduler: TestScheduler
) -> LicenseClient {
    LicenseClient(
        storage: storage,
        post: { url, body, headers in
            try? await held.hold()
            return try await host.handle(url, body, headers)
        },
        now: { serverNoon },
        schedule: { delay, work in scheduler.add(delay, work) },
        publicKeys: ["test-2": "BA=="],
        verifier: StubVerifier(accepts: true),
        endpoint: { "http://license.test/api/v1" },
        identity: { IdentityBox().value })
}

// Several clients in one process share one record and one lock.
@Suite struct LicenseSharedRecordTests {
    @Test(.timeLimit(.minutes(1)), arguments: [
        reply(422, #"{"error":"invalid_license"}"#),
        grantReply(syntheticToken(periodEnd: "2026-12-01T00:00:00Z")),
        grantReply(syntheticToken(alg: "ES384")),
    ])
    func aSlowerClientKeepsTheLicenseAnotherClientStored(_ late: MockLicenseHost.Reply) async throws {
        let first = LicenseHarness()
        let held = HeldRequest()
        let host = MockLicenseHost()
        let scheduler = TestScheduler()
        let second = heldClient(first.storage, held, host, scheduler)
        let slow = Task { await second.modelLoaded(model: "redact", modelVersion: "v0.7.0") }
        await held.waitUntilHeld()

        await first.host.queue("license", grantReply(syntheticToken()))
        await first.load()
        #expect(first.stored.token == syntheticToken())
        #expect(first.stored.activatedModels == ["emo"])

        await host.queue("license", late)
        await held.release()
        await slow.value

        #expect(first.stored.activatedModels == ["emo", "redact"])
        #expect(first.stored.token == syntheticToken())
        #expect(try await host.bodies("activate", as: ActivateBody.self).map(\.license) == [syntheticToken()])
        #expect(scheduler.pending == 0)
        await second.modelLoaded(model: "redact", modelVersion: "v0.7.0")
        await first.load()
        #expect(await host.paths == ["license", "activate"])
        #expect(await first.host.paths == ["license"])
    }

    @Test(.timeLimit(.minutes(1)))
    func anActivationKeepsTheModelsAnotherClientAddedMeanwhile() async {
        let first = LicenseHarness()
        first.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test")
        let held = HeldRequest()
        let host = MockLicenseHost()
        let second = heldClient(first.storage, held, host, TestScheduler())
        let slow = Task { await second.modelLoaded(model: "redact", modelVersion: "v0.7.0") }
        await held.waitUntilHeld()

        await first.load("emo")
        #expect(first.stored.activatedModels == ["emo"])

        await held.release()
        await slow.value
        #expect(first.stored.activatedModels == ["emo", "redact"])
        #expect(first.stored.token == syntheticToken())
    }

    @Test(.timeLimit(.minutes(1)))
    func aLicenseStoredDuringASlowCheckIsKept() async {
        let first = LicenseHarness(now: novemberFirst + dayMs)
        first.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test")
        let held = HeldRequest()
        let second = LicenseHarness(
            now: novemberFirst + dayMs, storage: first.storage, verifier: GatedVerifier(held: held))
        let slow = Task { await second.load("redact") }
        await held.waitUntilHeld()

        let next = syntheticToken(periodEnd: "2026-12-01T00:00:00Z")
        await first.host.queue("license", grantReply(next, serverTime: "2026-11-02T00:00:00Z"))
        await first.load("emo")
        #expect(first.stored.token == next)

        await held.release()
        await slow.value
        #expect(first.stored.token == next)
        #expect(await second.host.paths == ["activate"])
        #expect(first.stored.activatedModels == ["emo", "redact"])
    }

    @Test func aRecordAnotherClientStoredReplacesTheCopyKeptInMemory() async throws {
        let first = LicenseHarness()
        let second = LicenseHarness(storage: first.storage)
        first.storage.dropsWrites = true
        await first.host.queue("license", grantReply(syntheticToken()))
        await first.load("emo")
        #expect(first.stored == StoredLicense())

        first.storage.dropsWrites = false
        let other = syntheticToken(periodEnd: "2026-12-01T00:00:00Z")
        await second.host.queue("license", grantReply(other))
        await second.load("redact")
        #expect(first.stored.token == other)

        await first.load("shapes")
        #expect(first.stored.token == other)
        #expect(first.stored.activatedModels == ["redact", "shapes"])
        #expect(try await first.host.bodies("activate", as: ActivateBody.self).map(\.license) == [other])
    }

    @Test(.timeLimit(.minutes(1)))
    func aLateRefusalForAReplacedTokenActivatesOnTheNewToken() async throws {
        let first = LicenseHarness()
        first.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test")
        let held = HeldRequest()
        let host = MockLicenseHost()
        let second = heldClient(first.storage, held, host, TestScheduler())
        let slow = Task { await second.modelLoaded(model: "redact", modelVersion: "v0.7.0") }
        await held.waitUntilHeld()

        let next = syntheticToken(periodEnd: "2026-12-01T00:00:00Z")
        first.storage.saveLicense(StoredLicense(token: next, activatedModels: ["emo"]), "dal_test")
        await host.queue("activate", reply(422, #"{"error":"invalid_license"}"#))
        await held.release()
        await slow.value

        #expect(first.stored == StoredLicense(token: next, activatedModels: ["emo", "redact"]))
        #expect(try await host.bodies("activate", as: ActivateBody.self).map(\.license) == [syntheticToken(), next])
    }

    @Test(.timeLimit(.minutes(1)))
    func anActivationForAReplacedTokenIsSentAgainUnderTheNewLicense() async throws {
        let first = LicenseHarness()
        first.storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test")
        let held = HeldRequest()
        let host = MockLicenseHost()
        let scheduler = TestScheduler()
        let second = heldClient(first.storage, held, host, scheduler)
        let slow = Task { await second.modelLoaded(model: "redact", modelVersion: "v0.7.0") }
        await held.waitUntilHeld()

        let next = syntheticToken(periodEnd: "2026-12-01T00:00:00Z")
        let replaced = StoredLicense(token: next, activatedModels: ["emo"])
        first.storage.saveLicense(replaced, "dal_test")
        await host.queue("activate", activatedReply)
        await host.queue("activate", reply(503, #"{"error":"retry"}"#))
        await held.release()
        await slow.value

        #expect(try await host.bodies("activate", as: ActivateBody.self).map(\.license) == [syntheticToken(), next])
        #expect(first.stored == replaced)
        #expect(scheduler.pending == 1)

        await scheduler.fire()
        #expect(try await host.bodies("activate", as: ActivateBody.self).map(\.license) == [syntheticToken(), next, next])
        #expect(first.stored == StoredLicense(token: next, activatedModels: ["emo", "redact"]))
        #expect(scheduler.pending == 0)
    }

    #if !os(WASI)
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func clientsThatRequestALicenseAtTheSameMomentAllEndInTheList(expired: Bool) async {
        let models = (0..<8).map { "model-\($0)" }
        let now = novemberFirst + dayMs
        let next = syntheticToken(periodEnd: "2026-12-01T00:00:00Z")
        for round in 0..<200 {
            let storage = SharedStorage()
            if expired { storage.saveLicense(StoredLicense(token: syntheticToken(), activatedModels: ["emo"]), "dal_test") }
            let clients = models.map { _ in LicenseHarness(now: now, storage: storage) }
            for client in clients {
                await client.host.queue("license", grantReply(next, serverTime: "2026-11-02T00:00:00Z"))
            }
            await withTaskGroup(of: Void.self) { group in
                for (client, model) in zip(clients, models) {
                    group.addTask { await client.load(model) }
                }
            }
            let stored = storage.loadLicense("dal_test")
            guard stored.token == next, Set(stored.activatedModels ?? []) == Set(models),
                  stored.activatedModels?.count == models.count
            else {
                Issue.record("round \(round) kept \(stored.activatedModels ?? [])")
                return
            }
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func clientsThatActivateAtTheSameMomentAllEndInTheList() async {
        let models = (0..<8).map { "model-\($0)" }
        for round in 0..<200 {
            let storage = SharedStorage()
            storage.saveLicense(StoredLicense(token: syntheticToken()), "dal_test")
            let clients = models.map { _ in LicenseHarness(storage: storage) }
            await withTaskGroup(of: Void.self) { group in
                for (client, model) in zip(clients, models) {
                    group.addTask { await client.load(model) }
                }
            }
            let stored = storage.loadLicense("dal_test")
            guard Set(stored.activatedModels ?? []) == Set(models), stored.activatedModels?.count == models.count else {
                Issue.record("round \(round) kept \(stored.activatedModels ?? [])")
                return
            }
        }
    }
    #endif

    @Test func aRetryAfterAnotherClientStoredTheLicenseOnlyActivates() async {
        let first = LicenseHarness()
        let second = LicenseHarness(storage: first.storage)
        await second.host.queue("license", reply(503, #"{"error":"retry"}"#))
        await second.load("redact")
        #expect(second.scheduler.pending == 1)

        await first.host.queue("license", grantReply(syntheticToken()))
        await first.load("emo")
        await second.scheduler.fire()

        #expect(await second.host.paths == ["license", "activate"])
        #expect(first.stored.token == syntheticToken())
        #expect(first.stored.activatedModels == ["emo", "redact"])
        #expect(second.scheduler.pending == 0)
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
        identity: { LicenseIdentity(appId: "com.acme.app", apiKey: nil, platform: "server") },
        secret: { nil })
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
        #expect(h.stored.token == nil)
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
                _ = try? await host.handle(url, body, headers)
                try await held.hold()
                throw NetworkDown()
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
        let other = await clock.measure { await client.modelLoaded(model: "redact", modelVersion: "v0.7.0") }

        #expect(again < .seconds(5))
        #expect(other < .seconds(5))
        #expect(await host.paths == ["license"])
        #expect(scheduler.pending == 0)

        await held.release()
        await hung.value
        #expect(await host.paths == ["license"])
        #expect(scheduler.delays == [licenseNetworkRetryMs])
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
