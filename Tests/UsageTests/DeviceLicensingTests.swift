import PlatformSupport
import Testing
@testable import Usage

private struct GrantBody: Decodable {
    struct App: Decodable { var id: String }
    var installId: String
    var model: String
    var modelVersion: String
    var platform: String
    var app: App
}

private actor SendGate {
    private var isOpen: Bool
    private var isEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(open: Bool = false) {
        isOpen = open
    }

    func close() {
        isOpen = false
        isEntered = false
    }

    func enter() async {
        isEntered = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
        while !isOpen { await withCheckedContinuation { waiters.append($0) } }
    }

    func entered() async {
        while !isEntered { await withCheckedContinuation { waiters.append($0) } }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}

private struct BatchBody: Decodable {
    struct App: Decodable { var id: String }
    struct Item: Decodable, Equatable {
        var installId: String
        var model: String
        var modelVersion: String
    }
    var platform: String
    var app: App
    var items: [Item]
}

private struct DeviceHarness {
    static let secret = "0123456789abcdef0123456789abcdef"

    let host = MockLicenseHost()
    let clock: TestClock
    let scheduler = TestScheduler()
    let identity = IdentityBox()
    let holds = DeviceLicenseHolds()
    let client: DeviceLicenseClient

    init(
        now: Int64 = serverNoon, apiKey: String? = nil, secret: String? = DeviceHarness.secret,
        verifier: StubVerifier = StubVerifier(accepts: true), queueLimit: Int = deviceLicenseQueueLimit,
        batchItems: Int? = 10
    ) {
        let host = host, clock = TestClock(now), identity = identity, scheduler = scheduler
        self.clock = clock
        identity.value = LicenseIdentity(appId: "acme-api", apiKey: apiKey, platform: "server")
        let post: LicenseClient.Post = { url, body, headers in try await host.handle(url, body, headers) }
        // nil keeps the client's own batch size.
        if let batchItems {
            client = DeviceLicenseClient(
                holds: holds, queueLimit: queueLimit, batchItems: batchItems, post: post,
                now: { clock.ms },
                schedule: { delay, work in scheduler.add(delay, work) },
                canSchedule: { scheduler.canSchedule },
                jitter: { $0 },
                publicKeys: ["test-2": "BA=="],
                verifier: verifier,
                endpoint: { "http://license.test/api/v1/" },
                identity: { identity.value },
                secret: { secret })
        } else {
            client = DeviceLicenseClient(
                holds: holds, queueLimit: queueLimit, post: post,
                now: { clock.ms },
                schedule: { delay, work in scheduler.add(delay, work) },
                canSchedule: { scheduler.canSchedule },
                jitter: { $0 },
                publicKeys: ["test-2": "BA=="],
                verifier: verifier,
                endpoint: { "http://license.test/api/v1/" },
                identity: { identity.value },
                secret: { secret })
        }
    }

    // What `licenseOnRun` does, without the detached task.
    func want(_ deviceId: String, model: String = "emo") async {
        guard holds.begin(deviceId: deviceId, model: model, at: clock.ms) else { return }
        await client.license(deviceId: deviceId, model: model, modelVersion: "v0.7.0")
    }

    func run(_ deviceId: String, model: String = "emo") async {
        await want(deviceId, model: model)
        await client.flush()
    }

    // Lets each timer run at its time, until none is left.
    func settle() async {
        for _ in 0..<10 where scheduler.pending > 0 {
            clock.ms += scheduler.delays.last ?? 0
            await scheduler.fire()
        }
    }

    func installId(_ deviceId: String) -> String {
        deviceInstallId(deviceId: deviceId, app: "server:acme-api", secret: DeviceHarness.secret)
    }

    var grants: [GrantBody] {
        get async throws { try await host.bodies("license", as: GrantBody.self) }
    }

    var batches: [BatchBody] {
        get async throws { try await host.bodies("licenses", as: BatchBody.self) }
    }
}

func batchReply(_ results: [String], serverTime: String = "2026-10-07T12:00:00.000Z") -> MockLicenseHost.Reply {
    reply(200, #"{"serverTime":"\#(serverTime)","results":[\#(results.joined(separator: ","))]}"#)
}

func granted(_ token: String = syntheticToken()) -> String {
    #"{"token":"\#(token)","licenseId":"efe0d0d2-a957-8026-8b33-e6618d4f4dff","period":"2026-10","periodEnd":"2026-11-01T00:00:00Z"}"#
}

@Suite struct DeviceLicensingTests {
    @Test func aRunForADeviceAsksForItsLicenseWithTheDerivedInstallId() async throws {
        let h = DeviceHarness()
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.run("device-7")

        let sent = try await h.grants
        try #require(sent.count == 1)
        #expect(sent[0].installId == h.installId("device-7"))
        #expect(sent[0].installId != "device-7")
        #expect(sent[0].model == "emo")
        #expect(sent[0].modelVersion == "v0.7.0")
        #expect(sent[0].platform == "server")
        #expect(sent[0].app.id == "acme-api")
        #expect(await h.host.requests[0].headers["Authorization"] == nil)
    }

    @Test func noSecretSendsThePlainHashOfTheDeviceId() async throws {
        let h = DeviceHarness(secret: nil)
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.run("device-7")

        #expect(try await h.grants.map(\.installId) == [deviceInstallId(deviceId: "device-7", app: "server:acme-api", secret: nil)])
    }

    @Test func laterRunsForTheDeviceSendNothingUntilItsLicenseExpires() async throws {
        let h = DeviceHarness()
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.host.queue("license", grantReply(syntheticToken(periodEnd: "2026-12-01T00:00:00Z")))

        await h.run("device-7")
        await h.run("device-7")
        h.clock.ms = novemberFirst - 1
        await h.run("device-7")
        #expect(try await h.grants.count == 1)

        h.clock.ms = novemberFirst
        await h.run("device-7")
        #expect(try await h.grants.count == 2)
    }

    @Test func eachDeviceAndEachModelGetsItsOwnRequest() async throws {
        let h = DeviceHarness()
        for _ in 0..<3 { await h.host.queue("license", grantReply(syntheticToken())) }

        await h.run("device-7")
        await h.run("device-8")
        await h.run("device-7", model: "redact")

        let sent = try await h.grants
        #expect(sent.map(\.model) == ["emo", "emo", "redact"])
        #expect(sent[0].installId != sent[1].installId)
        #expect(sent[0].installId == sent[2].installId)
    }

    @Test func aRunWhileTheRequestIsInFlightSendsNoSecondRequest() {
        let holds = DeviceLicenseHolds()
        #expect(holds.begin(deviceId: "device-7", model: "emo", at: serverNoon))
        #expect(!holds.begin(deviceId: "device-7", model: "emo", at: serverNoon + deviceLicenseRequestHoldMs - 1))
        #expect(holds.begin(deviceId: "device-7", model: "emo", at: serverNoon + deviceLicenseRequestHoldMs))
    }

    @Test func theExpiryFollowsTheServerClock() async throws {
        let h = DeviceHarness(now: novemberFirst - 10 * minuteMs)
        await h.host.queue("license", grantReply(syntheticToken(), serverTime: "2026-10-31T23:55:00.000Z"))
        await h.host.queue("license", grantReply(syntheticToken(periodEnd: "2026-12-01T00:00:00Z")))

        await h.run("device-7")
        h.clock.ms = novemberFirst - 5 * minuteMs - 1
        await h.run("device-7")
        #expect(try await h.grants.count == 1)
        h.clock.ms = novemberFirst - 5 * minuteMs
        await h.run("device-7")
        #expect(try await h.grants.count == 2)
    }

    @Test func aRefusedModelWaitsADayForThatDeviceOnly() async throws {
        let h = DeviceHarness()
        await h.host.queue("license", reply(400, #"{"error":"invalid_request","message":"model nib is not a released model"}"#))
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.run("device-7", model: "nib")
        h.clock.ms += dayMs - 1
        await h.run("device-7", model: "nib")
        await h.run("device-7")
        #expect(try await h.grants.map(\.model) == ["nib", "emo"])

        h.clock.ms += 1
        await h.run("device-7", model: "nib")
        #expect(try await h.grants.count == 3)
    }

    @Test func aNetworkFailureKeepsTheDeviceQueuedAndTriesAgainAfterFiveMinutes() async throws {
        let h = DeviceHarness()
        await h.host.queue("license", .networkError)
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.run("device-7")
        h.clock.ms += deviceLicenseRequestHoldMs
        await h.want("device-7")
        #expect(await h.host.paths.count == 1)

        let failedAt = h.clock.ms - deviceLicenseRequestHoldMs
        await h.settle()
        #expect(await h.host.paths.count == 2)
        #expect(h.clock.ms - failedAt == licenseNetworkRetryMs)
    }

    @Test func aServerErrorBacksOffLongerEachTimeAndFollowsRetryAfter() async throws {
        let h = DeviceHarness()
        await h.host.queue("license", reply(503, #"{"error":"retry"}"#))
        await h.host.queue("license", reply(503, #"{"error":"retry"}"#, retryAfter: "600"))
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.run("device-7")
        await h.settle()

        #expect(await h.host.paths.count == 3)
        #expect(h.clock.ms - serverNoon == licenseMinBackoffMs + 600 * 1000)
    }

    @Test func aTimerThatFiresBeforeTheRetryIsDueSendsNothing() async throws {
        let h = DeviceHarness()
        await h.host.queue("license", .networkError)
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.run("device-7")
        await h.want("device-8")
        h.clock.ms += deviceLicenseBatchWaitMs
        await h.scheduler.fire()

        #expect(await h.host.paths.count == 1)
        #expect(h.scheduler.delays.last == licenseNetworkRetryMs - deviceLicenseBatchWaitMs)
    }

    @Test func aFailureStopsTheQueueAndTheRetrySendsOnlyWhatIsLeft() async throws {
        let h = DeviceHarness()
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.host.queue("license", .networkError)
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.want("device-1")
        await h.want("device-2")
        await h.want("device-3")
        await h.client.flush()
        #expect(try await h.grants.map(\.installId) == [h.installId("device-1"), h.installId("device-2")])

        await h.settle()
        #expect(try await h.grants.map(\.installId).suffix(2) == [h.installId("device-2"), h.installId("device-3")])
    }

    @Test func aTokenThatDoesNotVerifyWaitsADay() async throws {
        let h = DeviceHarness(verifier: StubVerifier(accepts: false))
        await h.host.queue("license", grantReply(syntheticToken()))
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.run("device-7")
        h.clock.ms += dayMs - 1
        await h.run("device-7")
        #expect(await h.host.paths.count == 1)
    }

    @Test func aFullTableForgetsExpiredDevicesFirstAndThenHalfOfTheRest() {
        let holds = DeviceLicenseHolds(capacity: 4)
        for device in ["a", "b", "c", "d"] { #expect(holds.begin(deviceId: device, model: "emo", at: 0)) }
        holds.hold(deviceId: "a", model: "emo", until: 10)
        for device in ["b", "c", "d"] { holds.hold(deviceId: device, model: "emo", until: 1000) }

        #expect(holds.begin(deviceId: "e", model: "emo", at: 20))
        #expect(["b", "c", "d"].allSatisfy { !holds.begin(deviceId: $0, model: "emo", at: 20) })

        holds.hold(deviceId: "e", model: "emo", until: 1000)
        #expect(holds.count == 4)
        #expect(holds.begin(deviceId: "f", model: "emo", at: 20))
        #expect(holds.count == 2)
    }

    @Test func withAnAPIKeyTheDevicesThatWaitGoInOneBatch() async throws {
        let h = DeviceHarness(apiKey: "dal_test")
        await h.host.queue("licenses", batchReply([granted(), granted(), granted()]))

        await h.want("device-1")
        await h.want("device-2")
        await h.want("device-1", model: "redact")
        #expect(await h.host.paths.isEmpty)
        #expect(h.scheduler.delays == [deviceLicenseBatchWaitMs])

        h.clock.ms += deviceLicenseBatchWaitMs
        await h.scheduler.fire()

        let sent = try await h.batches
        try #require(sent.count == 1)
        #expect(sent[0].platform == "server")
        #expect(sent[0].app.id == "acme-api")
        #expect(sent[0].items == [
            .init(installId: h.installId("device-1"), model: "emo", modelVersion: "v0.7.0"),
            .init(installId: h.installId("device-2"), model: "emo", modelVersion: "v0.7.0"),
            .init(installId: h.installId("device-1"), model: "redact", modelVersion: "v0.7.0"),
        ])
        #if !os(WASI)
        #expect(await h.host.requests[0].headers["Authorization"] == "Bearer dal_test")
        #endif
        #expect(await h.host.paths == ["licenses"])
    }

    // On wasm about a hundred awaits that do not suspend overflow the stack, so the tests use batches of 10.
    @Test func theDeviceThatFillsABatchSendsItAtOnceAndMoreDevicesGoInTheNext() async throws {
        let h = DeviceHarness(apiKey: "dal_test")
        await h.host.queue("licenses", batchReply(Array(repeating: granted(), count: 10)))
        await h.host.queue("licenses", batchReply([granted()]))

        for index in 0..<10 { await h.want("device-\(index)") }
        #expect(try await h.batches.map(\.items.count) == [10])

        await h.want("device-10")
        await h.client.flush()
        #expect(try await h.batches.map(\.items.count) == [10, 1])
    }

    @Test func aBatchIsAHundredDevicesByDefault() async throws {
        let h = DeviceHarness(apiKey: "dal_test", batchItems: nil)
        await h.host.queue("licenses", batchReply(Array(repeating: granted(), count: 100)))

        for index in 0..<99 {
            await h.want("device-\(index)")
            if index % 10 == 9 { await unwind() }
        }
        #expect(await h.host.paths.isEmpty)
        await unwind()
        await h.want("device-99")
        await unwind()

        #expect(deviceLicenseBatchItems == 100)
        #expect(try await h.batches.map(\.items.count) == [100])
    }

    @Test func eachDeviceOfABatchIsHeldUntilItsOwnResult() async throws {
        let h = DeviceHarness(apiKey: "dal_test")
        await h.host.queue("licenses", batchReply([
            granted(), #"{"error":"invalid_request","message":"model nib is not a released model"}"#,
        ]))
        await h.host.queue("licenses", batchReply([granted()]))

        await h.want("device-1")
        await h.want("device-1", model: "nib")
        await h.client.flush()

        h.clock.ms += dayMs
        await h.run("device-1")
        await h.run("device-1", model: "nib")
        #expect(try await h.batches.map { $0.items.map(\.model) } == [["emo", "nib"], ["nib"]])
    }

    @Test func aBatchTheServerRefusesIsSentAsSingleGrantsForAnHour() async throws {
        let h = DeviceHarness(apiKey: "dal_revoked")
        await h.host.queue("licenses", reply(400, #"{"error":"invalid_request","message":"a batch grant needs a valid API key"}"#))
        await h.host.queue("licenses", batchReply([granted()]))
        for _ in 0..<3 { await h.host.queue("license", grantReply(syntheticToken())) }

        await h.want("device-1")
        await h.want("device-2")
        await h.client.flush()
        #expect(await h.host.paths == ["licenses", "license", "license"])

        h.clock.ms += deviceLicenseSingleGrantsMs - 1
        await h.run("device-3")
        #expect(await h.host.paths.last == "license")

        h.clock.ms += 1
        await h.run("device-4")
        #expect(await h.host.paths.last == "licenses")
    }

    @Test func aServerWithoutTheBatchEndpointGetsSingleGrants() async throws {
        let h = DeviceHarness(apiKey: "dal_test")
        await h.host.queue("licenses", reply(404, #"{"message":"Not Found","statusCode":404}"#))
        await h.host.queue("license", grantReply(syntheticToken()))

        await h.run("device-1")

        #expect(await h.host.paths == ["licenses", "license"])
    }

    @Test func aBatchThatFailsStaysQueuedWholeAndIsSentAgain() async throws {
        let h = DeviceHarness(apiKey: "dal_test")
        await h.host.queue("licenses", reply(503, #"{"error":"retry"}"#, retryAfter: "60"))
        await h.host.queue("licenses", .networkError)
        await h.host.queue("licenses", batchReply([granted(), granted()]))

        await h.want("device-1")
        await h.want("device-2")
        await h.client.flush()
        await h.settle()

        #expect(try await h.batches.map(\.items.count) == [2, 2, 2])
        #expect(h.clock.ms - serverNoon == licenseMinBackoffMs + licenseNetworkRetryMs)
        h.clock.ms += deviceLicenseRequestHoldMs
        await h.run("device-1")
        #expect(await h.host.paths.count == 3)
    }

    @Test func anAnswerWithTheWrongNumberOfResultsIsSentAgain() async throws {
        let h = DeviceHarness(apiKey: "dal_test")
        await h.host.queue("licenses", batchReply([granted()]))
        await h.host.queue("licenses", batchReply([granted(), granted()]))

        await h.want("device-1")
        await h.want("device-2")
        await h.client.flush()
        await h.settle()

        #expect(try await h.batches.count == 2)
    }

    @Test func aFullQueueLeavesNewDevicesForALaterRun() async throws {
        let h = DeviceHarness(apiKey: "dal_test", queueLimit: 15)
        h.scheduler.canSchedule = false
        await h.host.queue("licenses", .networkError)
        for index in 0..<18 { await h.want("device-\(index)") }
        await h.host.queue("licenses", batchReply(Array(repeating: granted(), count: 10)))
        await h.host.queue("licenses", batchReply(Array(repeating: granted(), count: 5)))

        await h.client.flush()

        let sent = try await h.batches
        #expect(sent.map(\.items.count) == [1, 10, 5])
        #expect(sent[1].items.first?.installId == h.installId("device-0"))
        #expect(sent[2].items.last?.installId == h.installId("device-14"))
    }

    @Test func aFlushDoesNotSendBeforeTheTimeTheServerAskedFor() async throws {
        let h = DeviceHarness(apiKey: "dal_test")
        await h.host.queue("licenses", reply(503, #"{"error":"retry"}"#, retryAfter: "600"))
        await h.host.queue("licenses", batchReply([granted()]))

        await h.run("device-1")
        await h.client.flush()
        h.clock.ms += 600 * 1000 - 1
        await h.client.flush()
        #expect(await h.host.paths.count == 1)

        h.clock.ms += 1
        await h.client.flush()
        #expect(await h.host.paths.count == 2)
    }

    @Test func afterAFlushSendsAFailedBatchANewDeviceWaitsOnlyTheBatchTime() async throws {
        let h = DeviceHarness(apiKey: "dal_test")
        await h.host.queue("licenses", .networkError)
        await h.host.queue("licenses", batchReply([granted()]))
        await h.host.queue("licenses", batchReply([granted()]))

        await h.run("device-1")
        await h.client.flush()
        #expect(await h.host.paths.count == 2)

        await h.want("device-2")
        #expect(h.scheduler.delays.last == deviceLicenseBatchWaitMs)
        h.clock.ms += deviceLicenseBatchWaitMs
        await h.scheduler.fire()
        #expect(await h.host.paths.count == 3)
    }

    @Test func aHostWithoutTimersSendsEachDeviceAtOnce() async throws {
        let h = DeviceHarness(apiKey: "dal_test")
        h.scheduler.canSchedule = false
        await h.host.queue("licenses", batchReply([granted()]))

        await h.want("device-1")

        #expect(try await h.batches.map(\.items.count) == [1])
    }

    @Test func aRunWithADeviceIdAndAModelAsksOnceAndARunWithoutEitherAsksNothing() async throws {
        let h = DeviceHarness()
        await h.host.queue("license", grantReply(syntheticToken()))
        let sdk = SDKInfo(name: "desert-ant-core", version: "0", model: "emo", modelVersion: "v0.7.0")

        let work = InflightWork()
        licenseOnRun(sdk, deviceId: nil, client: h.client, work: work)
        licenseOnRun(sdk, deviceId: "", client: h.client, work: work)
        licenseOnRun(SDKInfo(), deviceId: "device-7", client: h.client, work: work)
        licenseOnRun(sdk, deviceId: "device-7", client: h.client, work: work)
        licenseOnRun(sdk, deviceId: "device-7", client: h.client, work: work)
        for entry in work.snapshot() { await entry.task.value }
        await h.client.flush()

        let sent = try await h.grants
        #expect(sent.map(\.installId) == [h.installId("device-7")])
        #expect(sent.first?.modelVersion == "v0.7.0")
    }

    @Test func aReplyForADeviceTheFullTableForgotDoesNotGrowTheTable() {
        let holds = DeviceLicenseHolds(capacity: 2)
        #expect(holds.begin(deviceId: "a", model: "emo", at: 0))
        #expect(holds.begin(deviceId: "b", model: "emo", at: 0))
        holds.hold(deviceId: "a", model: "emo", until: 1000)
        holds.hold(deviceId: "b", model: "emo", until: 1000)

        holds.hold(deviceId: "late", model: "emo", until: 1000)

        #expect(holds.count == 2)
        #expect(!holds.begin(deviceId: "a", model: "emo", at: 1))
    }

    @Test func aDeviceThatArrivesDuringASendGoesInTheNextBatch() async throws {
        let gate = SendGate()
        let host = MockLicenseHost()
        await host.queue("licenses", batchReply([granted()]))
        await host.queue("licenses", batchReply([granted()]))
        let clock = TestClock(serverNoon)
        let client = DeviceLicenseClient(
            batchItems: 10,
            post: { url, body, headers in
                await gate.enter()
                return try await host.handle(url, body, headers)
            },
            now: { clock.ms },
            schedule: { _, _ in },
            canSchedule: { true },
            publicKeys: ["test-2": "BA=="],
            verifier: StubVerifier(accepts: true),
            endpoint: { "http://license.test/api/v1/" },
            identity: { LicenseIdentity(appId: "acme-api", apiKey: "dal_test", platform: "server") },
            secret: { DeviceHarness.secret })
        await client.license(deviceId: "device-1", model: "emo", modelVersion: "v0.7.0")

        let sending = Task { await client.flush() }
        await gate.entered()
        await client.license(deviceId: "device-2", model: "emo", modelVersion: "v0.7.0")
        await client.license(deviceId: "device-1", model: "emo", modelVersion: "v0.7.0")
        await gate.open()
        await sending.value

        #expect(try await host.bodies("licenses", as: BatchBody.self).map(\.items.count) == [1, 1])
    }

    @Test func aPhoneOrAPageThatPassesADeviceIdAsksForNothing() async throws {
        let host = MockLicenseHost()
        let client = DeviceLicenseClient(
            batchItems: 10,
            post: { url, body, headers in try await host.handle(url, body, headers) },
            identity: { LicenseIdentity(appId: "acme.com", apiKey: nil, platform: "web") })
        let work = InflightWork()
        let sdk = SDKInfo(name: "desert-ant-core", version: "0", model: "emo", modelVersion: "v0.7.0")

        licenseOnRun(sdk, deviceId: "device-7", client: client, work: work)
        for entry in work.snapshot() { await entry.task.value }
        await client.flush()

        #expect(await host.paths.isEmpty)
        #expect(work.registeredTotal == 0)
    }

    @Test func aFlushStartsNoRequestAfterItsTimeAndLeavesTheRestForTheTimer() async throws {
        let host = MockLicenseHost()
        await host.queue("licenses", .networkError)
        for _ in 0..<3 { await host.queue("licenses", batchReply(Array(repeating: granted(), count: 10))) }
        let clock = TestClock(serverNoon)
        let scheduler = TestScheduler()
        let client = DeviceLicenseClient(
            batchItems: 10,
            post: { url, body, headers in
                clock.ms += 6 * 1000
                return try await host.handle(url, body, headers)
            },
            now: { clock.ms },
            schedule: { delay, work in scheduler.add(delay, work) },
            canSchedule: { scheduler.canSchedule },
            publicKeys: ["test-2": "BA=="],
            verifier: StubVerifier(accepts: true),
            endpoint: { "http://license.test/api/v1/" },
            identity: { LicenseIdentity(appId: "acme-api", apiKey: "dal_test", platform: "server") },
            secret: { DeviceHarness.secret })
        for index in 0..<30 {
            await client.license(deviceId: "device-\(index)", model: "emo", modelVersion: "v0.7.0")
        }
        await unwind()
        #expect(await host.paths.count == 1)
        // The first timer has fired, so only the far retry timer is left.
        await scheduler.fire()
        await unwind()
        let armed = scheduler.delays.count

        let sentAll = await client.flush(within: 10 * 1000)

        await unwind()
        #expect(!sentAll)
        #expect(await host.paths.count == 3)
        #expect(scheduler.delays.count == armed + 1)
        #expect(scheduler.delays.last == deviceLicenseBatchWaitMs)

        clock.ms += deviceLicenseBatchWaitMs
        await scheduler.fire()
        await unwind()
        #expect(await host.paths.count == 4)
        #expect(await client.flush(within: 10 * 1000))
        #expect(await host.paths.count == 4)
    }

    // On wasm an await that does not suspend keeps its frames, so a long test gives the stack back here.
    private func unwind() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { continuation.resume() }
        }
    }

    private func limits(_ count: Int, on client: DeviceLicenseClient) async {
        for _ in 0..<10_000 {
            if await client.activeLimits >= count { return }
            await Task.yield()
        }
    }

    // 30 devices in batches of 10, a failed first request so that nothing is sent before the flush, and 6 s per request.
    private func slowClient(
        apiKey: String?, replies: Int = 6, gate: SendGate = SendGate(open: true)
    ) async -> (client: DeviceLicenseClient, host: MockLicenseHost, clock: TestClock) {
        let host = MockLicenseHost()
        let path = apiKey == nil ? "license" : "licenses"
        await host.queue(path, .networkError)
        for _ in 0..<replies {
            await host.queue(path, apiKey == nil ? grantReply(syntheticToken()) : batchReply(Array(repeating: granted(), count: 10)))
        }
        let clock = TestClock(serverNoon)
        let client = DeviceLicenseClient(
            batchItems: 10,
            post: { url, body, headers in
                await gate.enter()
                clock.ms += 6 * 1000
                return try await host.handle(url, body, headers)
            },
            now: { clock.ms },
            schedule: { _, _ in },
            canSchedule: { true },
            publicKeys: ["test-2": "BA=="],
            verifier: StubVerifier(accepts: true),
            endpoint: { "http://license.test/api/v1/" },
            identity: { LicenseIdentity(appId: "acme-api", apiKey: apiKey, platform: "server") },
            secret: { DeviceHarness.secret })
        for index in 0..<30 {
            await client.license(deviceId: "device-\(index)", model: "emo", modelVersion: "v0.7.0")
        }
        return (client, host, clock)
    }

    @Test func ofTwoFlushesAtOnceTheEarlierLimitHolds() async throws {
        let gate = SendGate(open: true)
        let (client, host, _) = await slowClient(apiKey: "dal_test", gate: gate)
        await gate.close()

        let long = Task { await client.flush(within: 60 * 60 * 1000) }
        await gate.entered()
        let short = Task { await client.flush(within: 10 * 1000) }
        await limits(2, on: client)
        await gate.open()

        #expect(await long.value == false)
        #expect(await short.value == false)
        #expect(await host.paths.count == 3)
    }

    @Test func aFlushWithoutBatchesChecksItsTimeBeforeEachRequest() async throws {
        let (client, host, _) = await slowClient(apiKey: nil)

        #expect(await client.flush(within: 10 * 1000) == false)

        #expect(await host.paths.count == 3)
    }

    @Test func flushAndWaitStopsASendThatAlreadyRuns() async throws {
        let gate = SendGate(open: true)
        let (client, host, clock) = await slowClient(apiKey: "dal_test", gate: gate)
        await gate.close()
        let work = InflightWork()
        dispatchTracked(into: work) { await client.flush(within: 60 * 60 * 1000) }
        await gate.entered()

        let flushing = Task { await LicenseFlush(work: work, client: client, now: { clock.ms }).flushAndWait() }
        await limits(2, on: client)
        await gate.open()
        let sentAll = await flushing.value

        #expect(!sentAll)
        #expect(await host.paths.count == 3)
        #expect(await client.flush(within: 60 * 60 * 1000))
        #expect(await host.paths.count == 4)
    }

    @Test func aFlushWaitsForASendThatIsInFlight() async throws {
        let gate = SendGate()
        let host = MockLicenseHost()
        await host.queue("licenses", batchReply([granted()]))
        let clock = TestClock(serverNoon)
        let client = DeviceLicenseClient(
            batchItems: 10,
            post: { url, body, headers in
                await gate.enter()
                return try await host.handle(url, body, headers)
            },
            now: { clock.ms },
            schedule: { _, _ in },
            canSchedule: { true },
            publicKeys: ["test-2": "BA=="],
            verifier: StubVerifier(accepts: true),
            endpoint: { "http://license.test/api/v1/" },
            identity: { LicenseIdentity(appId: "acme-api", apiKey: "dal_test", platform: "server") },
            secret: { DeviceHarness.secret })
        await client.license(deviceId: "device-1", model: "emo", modelVersion: "v0.7.0")

        let first = Task { await client.flush() }
        await gate.entered()
        let second = Task { await client.flush() }
        for _ in 0..<50 { await Task.yield() }
        #expect(await host.paths.isEmpty)

        await gate.open()
        await first.value
        await second.value
        #expect(await host.paths == ["licenses"])
    }

    private func gatedClient(
        _ gate: SendGate, batches: [Int]
    ) async -> (client: DeviceLicenseClient, host: MockLicenseHost, clock: TestClock, scheduler: TestScheduler) {
        let host = MockLicenseHost()
        for count in batches { await host.queue("licenses", batchReply(Array(repeating: granted(), count: count))) }
        let clock = TestClock(serverNoon)
        let scheduler = TestScheduler()
        let client = DeviceLicenseClient(
            batchItems: 10,
            post: { url, body, headers in
                await gate.enter()
                return try await host.handle(url, body, headers)
            },
            now: { clock.ms },
            schedule: { delay, work in scheduler.add(delay, work) },
            canSchedule: { true },
            publicKeys: ["test-2": "BA=="],
            verifier: StubVerifier(accepts: true),
            endpoint: { "http://license.test/api/v1/" },
            identity: { LicenseIdentity(appId: "acme-api", apiKey: "dal_test", platform: "server") },
            secret: { DeviceHarness.secret })
        return (client, host, clock, scheduler)
    }

    private func sizes(_ host: MockLicenseHost) async throws -> [Int] {
        try await host.bodies("licenses", as: BatchBody.self).map(\.items.count)
    }

    @Test func aSteadyTrickleGoesOutInFullBatches() async throws {
        let gate = SendGate()
        let (client, host, clock, scheduler) = await gatedClient(gate, batches: [10, 10, 2])
        let arrive: @Sendable (Int) async -> Void = { index in
            await client.license(deviceId: "device-\(index)", model: "emo", modelVersion: "v0.7.0")
        }

        for index in 0..<9 { await arrive(index) }
        await unwind()
        let first = Task { await arrive(9) }
        await gate.entered()
        for index in 10..<13 { await arrive(index) }
        await gate.open()
        await first.value
        try #require(try await sizes(host) == [10])

        await gate.close()
        await unwind()
        for index in 13..<19 { await arrive(index) }
        #expect(try await sizes(host) == [10])
        let second = Task { await arrive(19) }
        await gate.entered()
        clock.ms += 1000
        for index in 20..<22 { await arrive(index) }
        await gate.open()
        await second.value
        await unwind()
        #expect(try await sizes(host) == [10, 10])

        clock.ms += deviceLicenseBatchWaitMs
        await scheduler.fire()
        #expect(try await sizes(host) == [10, 10, 2])
    }

    @Test func aLoneDeviceGoesOutWhenItHasWaitedTheBatchTime() async throws {
        let h = DeviceHarness(apiKey: "dal_test")
        await h.host.queue("licenses", batchReply([granted()]))

        await h.want("device-1")
        h.clock.ms += deviceLicenseBatchWaitMs - 1
        await h.scheduler.fire()
        #expect(await h.host.paths.isEmpty)
        #expect(h.scheduler.delays.last == 1)

        h.clock.ms += 1
        await h.scheduler.fire()
        #expect(try await h.batches.map(\.items.count) == [1])
    }

    @Test func aDeviceThatArrivesDuringASendWaitsTheBatchTimeFromItsOwnArrival() async throws {
        let gate = SendGate()
        let (client, host, clock, scheduler) = await gatedClient(gate, batches: [10, 1])

        for index in 0..<9 {
            await client.license(deviceId: "device-\(index)", model: "emo", modelVersion: "v0.7.0")
        }
        await unwind()
        let filling = Task { await client.license(deviceId: "device-9", model: "emo", modelVersion: "v0.7.0") }
        await gate.entered()
        clock.ms += 3 * 1000
        await client.license(deviceId: "late", model: "emo", modelVersion: "v0.7.0")
        clock.ms += 5 * 1000
        await gate.open()
        await filling.value
        #expect(try await sizes(host) == [10])

        clock.ms += 2 * 1000
        await scheduler.fire()
        #expect(try await sizes(host) == [10])
        await unwind()
        let timers: [Int64] = [deviceLicenseBatchWaitMs, 3 * 1000]
        #expect(scheduler.delays == timers)

        clock.ms += 3 * 1000
        await scheduler.fire()
        #expect(try await sizes(host) == [10, 1])
    }

    private final class Warnings: @unchecked Sendable {
        var texts: [String] = []
    }

    private func warningClient(
        _ host: MockLicenseHost, _ clock: TestClock, _ scheduler: TestScheduler, _ warnings: Warnings,
        queueLimit: Int = deviceLicenseQueueLimit, apiKey: String? = "dal_test_key"
    ) -> DeviceLicenseClient {
        DeviceLicenseClient(
            queueLimit: queueLimit,
            batchItems: 10,
            post: { url, body, headers in try await host.handle(url, body, headers) },
            now: { clock.ms },
            schedule: { delay, work in scheduler.add(delay, work) },
            canSchedule: { true },
            jitter: { $0 },
            publicKeys: ["test-2": "BA=="],
            verifier: StubVerifier(accepts: true),
            endpoint: { "http://license.test/api/v1/" },
            identity: { LicenseIdentity(appId: "acme-api", apiKey: apiKey, platform: "server") },
            secret: { DeviceHarness.secret },
            warn: { warnings.texts.append($0) })
    }

    @Test func aFullQueueIsLoggedOnce() async throws {
        let warnings = Warnings()
        let client = warningClient(MockLicenseHost(), TestClock(serverNoon), TestScheduler(), warnings, queueLimit: 3)

        for index in 0..<3 { await client.license(deviceId: "device-\(index)", model: "emo", modelVersion: "v0.7.0") }
        #expect(warnings.texts.isEmpty)
        await client.license(deviceId: "device-1", model: "emo", modelVersion: "v0.7.0")
        #expect(warnings.texts.isEmpty)

        for index in 3..<6 { await client.license(deviceId: "device-\(index)", model: "emo", modelVersion: "v0.7.0") }
        try #require(warnings.texts.count == 1)
        #expect(warnings.texts[0].contains("license queue is full"))
        #expect(warnings.texts[0].contains("later call"))
        #expect(warnings.texts[0].contains("license server"))
        #expect(!warnings.texts[0].contains("device-"))
    }

    @Test func aFailureStreakIsLoggedOnceAndAgainAfterASuccess() async throws {
        let warnings = Warnings()
        let host = MockLicenseHost(), clock = TestClock(serverNoon), scheduler = TestScheduler()
        let client = warningClient(host, clock, scheduler, warnings)
        await host.queue("licenses", .networkError)
        await host.queue("licenses", reply(503, #"{"error":"retry"}"#))
        await host.queue("licenses", batchReply([granted()]))
        await host.queue("licenses", reply(429, #"{"error":"retry"}"#, retryAfter: "120"))
        await host.queue("licenses", batchReply([granted()]))

        await client.license(deviceId: "device-secret-1", model: "emo", modelVersion: "v0.7.0")
        await client.flush()
        try #require(warnings.texts.count == 1)
        #expect(warnings.texts[0].contains("no answer"))
        #expect(warnings.texts[0].contains("tries again in 300 s"))
        #expect(warnings.texts[0].contains("The model keeps running"))

        await client.flush()
        #expect(await host.paths.count == 2)
        #expect(warnings.texts.count == 1)

        clock.ms += licenseMinBackoffMs
        await client.flush()
        #expect(await host.paths.count == 3)
        #expect(warnings.texts.count == 1)

        await client.license(deviceId: "device-secret-2", model: "emo", modelVersion: "v0.7.0")
        await client.flush()
        try #require(warnings.texts.count == 2)
        #expect(warnings.texts[1].contains("HTTP 429"))
        #expect(warnings.texts[1].contains("tries again in 120 s"))

        clock.ms += 120 * 1000
        await client.flush()
        #expect(await host.paths.count == 5)
        #expect(warnings.texts.count == 2)
        for text in warnings.texts {
            #expect(!text.contains("dal_test_key"))
            #expect(!text.contains(DeviceHarness.secret))
            #expect(!text.contains("device-secret"))
            #expect(!text.contains(deviceInstallId(deviceId: "device-secret-1", app: "server:acme-api", secret: DeviceHarness.secret)))
        }
    }

    @Test func aFailureWithoutBatchesIsLoggedToo() async throws {
        let warnings = Warnings()
        let host = MockLicenseHost()
        let client = warningClient(host, TestClock(serverNoon), TestScheduler(), warnings, apiKey: nil)
        await host.queue("license", reply(500, #"{"error":"retry"}"#))

        await client.license(deviceId: "device-1", model: "emo", modelVersion: "v0.7.0")
        await client.flush()

        #expect(warnings.texts.count == 1)
        #expect(warnings.texts.first?.contains("HTTP 500") == true)
    }

    @Test func aFullTableKeepsADeviceItAlreadyHolds() {
        let holds = DeviceLicenseHolds(capacity: 2)
        #expect(holds.begin(deviceId: "a", model: "emo", at: 0))
        #expect(holds.begin(deviceId: "b", model: "emo", at: 0))
        holds.hold(deviceId: "b", model: "emo", until: 2 * deviceLicenseRequestHoldMs)

        #expect(holds.begin(deviceId: "a", model: "emo", at: deviceLicenseRequestHoldMs))
        #expect(!holds.begin(deviceId: "b", model: "emo", at: deviceLicenseRequestHoldMs))
    }
}
