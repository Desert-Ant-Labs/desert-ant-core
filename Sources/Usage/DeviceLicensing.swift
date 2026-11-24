import JSON
import PlatformSupport
#if !os(WASI)
import Dispatch
#endif

let runOnAServerGuide = "https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/notes/server.md"
let deviceLicenseRequestHoldMs: Int64 = 60 * 1000
let deviceLicenseCapacity = 200_000
let deviceLicenseBatchItems = 100
let deviceLicenseBatchWaitMs: Int64 = 10 * 1000
let deviceLicenseQueueLimit = 10_000
let deviceLicenseSingleGrantsMs: Int64 = hourMs
let deviceLicenseFlushMs: Int64 = 10 * 1000

/// Starts the license check for the end-user device a run serves. A run without a device id
/// serves this install, which `licenseOnLoad` covers unless a device id secret is set.
package func licenseOnRun(_ sdk: SDKInfo, deviceId: String?) {
    licenseOnRun(sdk, deviceId: deviceId, client: .shared)
}

func licenseOnRun(
    _ sdk: SDKInfo, deviceId: String?, client: DeviceLicenseClient, work: InflightWork = .shared
) {
    // A phone or a page is one device, which its install license covers.
    guard client.servesFromAServer else { return }
    guard let deviceId, !deviceId.isEmpty else {
        if client.hasSecret, client.warnings.firstTime(.runWithoutDeviceId) {
            Log.warning("This call has no deviceId, so it gets no device license. Pass a deviceId with every call. See \(runOnAServerGuide)")
        }
        return
    }
    guard let model = sdk.model,
          client.holds.begin(deviceId: deviceId, model: model, at: systemNowMs())
    else { return }
    if !client.hasSecret, client.warnings.firstTime(.deviceIdWithoutSecret) {
        Log.warning("deviceId is hashed without a secret, so a guessed device id can be matched to its install id. Set deviceIdSecret in DesertAnt.configure. See \(runOnAServerGuide)")
    }
    let modelVersion = sdk.modelVersion ?? ""
    dispatchTracked(into: work) {
        await client.license(deviceId: deviceId, model: model, modelVersion: modelVersion)
    }
}

/// Until when each device and model needs no license request: its license's expiry, a day after
/// a refusal, or a minute while its request waits. Read on every run, so it is a lock and not an actor.
final class DeviceLicenseHolds: @unchecked Sendable {
    private var heldUntil: [String: Int64] = [:]
    private let capacity: Int

    init(capacity: Int = deviceLicenseCapacity) {
        self.capacity = capacity
    }

    func begin(deviceId: String, model: String, at now: Int64) -> Bool {
        withLock {
            let key = Self.key(deviceId, model)
            let held = heldUntil[key]
            if let held, now < held { return false }
            if held == nil, heldUntil.count >= capacity {
                heldUntil = heldUntil.filter { now < $0.value }
                // Forgetting a device only sends its request again, and the server answers with the same license.
                if heldUntil.count >= capacity {
                    for forgotten in heldUntil.keys.prefix(capacity / 2 + 1) { heldUntil[forgotten] = nil }
                }
            }
            heldUntil[key] = now &+ deviceLicenseRequestHoldMs
            return true
        }
    }

    func hold(deviceId: String, model: String, until time: Int64) {
        withLock {
            let key = Self.key(deviceId, model)
            guard heldUntil[key] != nil || heldUntil.count < capacity else { return }
            heldUntil[key] = time
        }
    }

    var count: Int { withLock { heldUntil.count } }

    static func key(_ deviceId: String, _ model: String) -> String {
        "\(model)\u{0}\(deviceId)"
    }

#if os(WASI)
    private func withLock<T>(_ body: () -> T) -> T { body() }
#else
    private let lock = DispatchSemaphore(value: 1)

    private func withLock<T>(_ body: () -> T) -> T {
        lock.wait()
        defer { lock.signal() }
        return body()
    }
#endif
}

final class DeviceLicenseWarnings: @unchecked Sendable {
    enum Warning {
        case runWithoutDeviceId
        case deviceIdWithoutSecret
        case queueFull
    }

    private var given: Set<Warning> = []

    func firstTime(_ warning: Warning) -> Bool {
        withLock { given.insert(warning).inserted }
    }

#if os(WASI)
    private func withLock<T>(_ body: () -> T) -> T { body() }
#else
    private let lock = DispatchSemaphore(value: 1)

    private func withLock<T>(_ body: () -> T) -> T {
        lock.wait()
        defer { lock.signal() }
        return body()
    }
#endif
}

struct LicenseBatchRequest: Encodable {
    struct Item: Encodable {
        var installId: String
        var model: String
        var modelVersion: String
    }

    var sdk: SDKInfo
    var platform: String
    var app: AppInfo
    var key: String?
    var items: [Item]
}

private struct LicenseBatchResponse: Decodable {
    struct Result: Decodable {
        var token: String?
    }

    var serverTime: String?
    var results: [Result]
}

/// Collects the devices that need a license and asks for them together, when a full batch waits
/// or a short time after the first. A batch needs an API key the server takes batches from;
/// without one, each device is one grant request.
actor DeviceLicenseClient {
    static let shared = DeviceLicenseClient()

    private struct Wanted {
        var deviceId: String
        var model: String
        var modelVersion: String
        var since: Int64
        var key: String { DeviceLicenseHolds.key(deviceId, model) }
    }

    nonisolated let holds: DeviceLicenseHolds
    nonisolated let warnings = DeviceLicenseWarnings()
    nonisolated var hasSecret: Bool { secret() != nil }
    nonisolated let servesFromAServer: Bool
    private let post: LicenseClient.Post
    private let now: @Sendable () -> Int64
    private let schedule: LicenseScheduler
    private let canSchedule: @Sendable () -> Bool
    private let jitter: @Sendable (Int64) -> Int64
    private let publicKeys: [String: String]
    private let verifier: (any LicenseSignatureVerifier)?
    private let endpoint: @Sendable () -> String
    private let identity: @Sendable () -> LicenseIdentity
    private let secret: @Sendable () -> String?
    private let warn: @Sendable (String) -> Void

    private var queue: [Wanted] = []
    private var queued: Set<String> = []
    private var sending = false
    private var flushesWaiting: [CheckedContinuation<Void, Never>] = []
    private var flushes = 0
    private var flushEnds: Int64?
    private var timerDue: Int64?
    private var timerGeneration = 0
    private var attempts = 0
    // A flush sends before `retryAt`, and never before the time the server asked for.
    private var retryAt: Int64 = 0
    private var serverWaitUntil: Int64 = 0
    private var loggedBatchRefusal = false
    private var loggedRetryWait = false
    private var singleGrantsUntil: Int64 = 0
    private let queueLimit: Int
    private let batchItems: Int

    init(
        holds: DeviceLicenseHolds = DeviceLicenseHolds(),
        queueLimit: Int = deviceLicenseQueueLimit,
        batchItems: Int = deviceLicenseBatchItems,
        post: @escaping LicenseClient.Post = { url, body, headers in
            try await httpPOST(url, body: body, headers: headers, timeout: licenseTimeoutSeconds)
        },
        now: @escaping @Sendable () -> Int64 = systemNowMs,
        schedule: @escaping LicenseScheduler = scheduleLicenseRetry,
        canSchedule: @escaping @Sendable () -> Bool = canScheduleLicenseRetry,
        jitter: @escaping @Sendable (Int64) -> Int64 = { Int64.random(in: 0...$0) },
        publicKeys: [String: String] = licensePublicKeys,
        verifier: (any LicenseSignatureVerifier)? = defaultLicenseVerifier(),
        endpoint: @escaping @Sendable () -> String = { hostProvidedLicenseEndpoint() ?? defaultLicenseEndpoint },
        identity: @escaping @Sendable () -> LicenseIdentity = currentLicenseIdentity,
        secret: @escaping @Sendable () -> String? = { DesertAnt.configuredDeviceIdSecret },
        warn: @escaping @Sendable (String) -> Void = { Log.warning($0) }
    ) {
        self.holds = holds
        self.queueLimit = queueLimit
        self.batchItems = batchItems
        self.post = post
        self.now = now
        self.schedule = schedule
        self.canSchedule = canSchedule
        self.jitter = jitter
        self.publicKeys = publicKeys
        self.verifier = verifier
        self.endpoint = endpoint
        self.identity = identity
        self.secret = secret
        self.warn = warn
        servesFromAServer = identity().platform == "server"
    }

    func license(deviceId: String, model: String, modelVersion: String) async {
        let wanted = Wanted(deviceId: deviceId, model: model, modelVersion: modelVersion, since: now())
        guard !queued.contains(wanted.key) else { return }
        // A device left out of a full queue asks again on a later run, when its hold ends.
        guard queue.count < queueLimit else {
            if warnings.firstTime(.queueFull) {
                warn("The license queue is full (\(queueLimit) devices wait), so new devices are left out and get a license on a later call. The model keeps running. Check that the license server is reachable and answers in time. See \(runOnAServerGuide)")
            }
            return
        }
        queued.insert(wanted.key)
        queue.append(wanted)
        if queue.count >= batchItems || !canSchedule() {
            await drain(force: false)
        } else {
            arm(after: max(deviceLicenseBatchWaitMs, retryAt &- now()))
        }
    }

    /// Sends what waits now, also before a network retry is due, never before a time the server asked for.
    /// It starts no request after `budget`, so a process that exits is not held up: what is left stays
    /// queued for the timer. Returns whether nothing is left.
    @discardableResult
    func flush(within budget: Int64 = deviceLicenseFlushMs) async -> Bool {
        limitSends(until: now() &+ budget)
        defer { endLimit() }
        // A send that another caller started must end before this one returns.
        while sending {
            await withCheckedContinuation { flushesWaiting.append($0) }
        }
        await drain(force: true)
        return queue.isEmpty
    }

    /// From now until `endLimit`, no request starts after `end`. With several limits, the earliest holds.
    func limitSends(until end: Int64) {
        flushes += 1
        flushEnds = min(flushEnds ?? .max, end)
    }

    var activeLimits: Int { flushes }

    func endLimit() {
        flushes -= 1
        if flushes == 0 { flushEnds = nil }
    }

    private var pastFlushLimit: Bool {
        flushEnds.map { now() >= $0 } ?? false
    }

    // One timer at a time. A sooner one replaces a later one, and the replaced one does nothing when it fires.
    private func arm(after delay: Int64) {
        guard canSchedule() else { return }
        let due = now() &+ min(max(delay, 0), licenseMaxBackoffMs)
        if let timerDue, timerDue <= due { return }
        timerDue = due
        timerGeneration += 1
        let armed = timerGeneration
        schedule(due &- now()) { await self.timerFired(armed) }
    }

    private func timerFired(_ armed: Int) async {
        guard armed == timerGeneration else { return }
        timerDue = nil
        await drain(force: false)
    }

    private func drain(force: Bool) async {
        guard !sending else { return }
        let wait = (force ? serverWaitUntil : retryAt) &- now()
        if wait > 0 {
            arm(after: wait)
            return
        }
        sending = true
        defer {
            sending = false
            let waiting = flushesWaiting
            flushesWaiting = []
            for flush in waiting { flush.resume() }
        }
        while !queue.isEmpty {
            if pastFlushLimit {
                arm(after: deviceLicenseBatchWaitMs)
                return
            }
            // Less than a batch waits for more devices, until the oldest has waited its time.
            if !force, queue.count < batchItems, canSchedule() {
                let wait = queue[0].since &+ deviceLicenseBatchWaitMs &- now()
                if wait > 0, wait <= deviceLicenseBatchWaitMs {
                    arm(after: wait)
                    return
                }
            }
            let batch = Array(queue.prefix(batchItems))
            let (settled, retry) = await send(batch)
            for wanted in batch.prefix(settled) { queued.remove(wanted.key) }
            queue.removeFirst(settled)
            if let retry {
                if !loggedRetryWait {
                    loggedRetryWait = true
                    warn("Device licensing failed (\(retry.cause)) and tries again in \(max(retry.after / 1000, 1)) s. The model keeps running. Check that the license server is reachable. See \(runOnAServerGuide)")
                }
                retryAt = now() &+ retry.after
                if retry.server { serverWaitUntil = retryAt }
                arm(after: retry.after)
                return
            }
            retryAt = 0
            serverWaitUntil = 0
            loggedRetryWait = false
        }
    }

    private func installId(_ wanted: Wanted, _ who: LicenseIdentity) -> String {
        deviceInstallId(deviceId: wanted.deviceId, app: "\(who.platform):\(who.appId)", secret: secret(), apiKey: who.apiKey)
    }

    private typealias Retry = (after: Int64, server: Bool, cause: String)
    private static let noAnswer = "no answer: the connection failed or timed out"

    // How many of the batch are settled, from its start, and when to send the rest again.
    private func send(_ batch: [Wanted]) async -> (settled: Int, retry: Retry?) {
        let who = identity()
        guard who.apiKey != nil, now() >= singleGrantsUntil else { return await sendSingleGrants(batch, who) }
        let request = LicenseBatchRequest(
            sdk: SDKInfo(),
            platform: who.platform,
            app: AppInfo(id: who.appId),
            key: licenseKeyInBody ? who.apiKey : nil,
            items: batch.map { .init(installId: installId($0, who), model: $0.model, modelVersion: $0.modelVersion) })
        guard let payload = try? JSONEncoder().encode(request),
              let response = await postLicenseRequest("licenses", payload, apiKey: who.apiKey, endpoint: endpoint(), post: post)
        else { return (0, (licenseNetworkRetryMs, false, Self.noAnswer)) }
        let received = now()
        let action = licenseResponseAction(status: response.status, body: response.body)
        // The key cannot batch, or the server has no batch endpoint.
        if action == .terminal || response.status == 404 {
            singleGrantsUntil = received &+ deviceLicenseSingleGrantsMs
            if !loggedBatchRefusal {
                loggedBatchRefusal = true
                Log.log(
                    action == .terminal ? .warning : .info,
                    "The license server did not accept a batch (HTTP \(response.status)), so each device is one request for the next hour. A batch needs an API key of the Server platform. See \(runOnAServerGuide)")
            }
            return await sendSingleGrants(batch, who)
        }
        if action == .retryNetwork { return (0, (licenseNetworkRetryMs, false, Self.noAnswer)) }
        guard action == .done,
              let reply = try? JSONDecoder().decode(LicenseBatchResponse.self, from: response.body),
              reply.results.count == batch.count
        else { return (0, (backoff(response), true, action == .done ? "an answer the SDK cannot read" : "HTTP \(response.status)")) }
        attempts = 0
        for (index, (wanted, result)) in zip(batch, reply.results).enumerated() {
            #if os(WASI)
            // wasm keeps the frames of an await that does not suspend, and a full batch of them overflows the stack.
            if index % 8 == 7 { await Task.yield() }
            #endif
            let until = await expiry(of: result.token, serverTime: reply.serverTime, received: received)
            holds.hold(deviceId: wanted.deviceId, model: wanted.model, until: until)
        }
        return (batch.count, nil)
    }

    private func sendSingleGrants(_ batch: [Wanted], _ who: LicenseIdentity) async -> (settled: Int, retry: Retry?) {
        for (index, wanted) in batch.enumerated() {
            if pastFlushLimit { return (index, nil) }
            let request = LicenseGrantRequest(
                installId: installId(wanted, who),
                model: wanted.model,
                modelVersion: wanted.modelVersion,
                sdk: SDKInfo(),
                platform: who.platform,
                app: AppInfo(id: who.appId),
                key: licenseKeyInBody ? who.apiKey : nil)
            guard let payload = try? JSONEncoder().encode(request),
                  let response = await postLicenseRequest("license", payload, apiKey: who.apiKey, endpoint: endpoint(), post: post)
            else { return (index, (licenseNetworkRetryMs, false, Self.noAnswer)) }
            let received = now()
            let until: Int64
            switch licenseResponseAction(status: response.status, body: response.body) {
            case .retryNetwork:
                return (index, (licenseNetworkRetryMs, false, Self.noAnswer))
            case .retry:
                return (index, (backoff(response), true, "HTTP \(response.status)"))
            case .terminal:
                until = received &+ licenseTerminalWaitMs
            case .done:
                let granted = try? JSONDecoder().decode(LicenseGrantResponse.self, from: response.body)
                until = await expiry(of: granted?.token, serverTime: granted?.serverTime, received: received)
                attempts = 0
            }
            holds.hold(deviceId: wanted.deviceId, model: wanted.model, until: until)
        }
        return (batch.count, nil)
    }

    private func backoff(_ response: HTTPResponse) -> Int64 {
        attempts += 1
        return licenseBackoff(attempt: attempts - 1, retryAfter: licenseRetryAfter(response), jitter: jitter)
    }

    // The local time until which the device needs no request: its license's expiry, or a day for an answer without a license that verifies.
    private func expiry(of token: String?, serverTime: String?, received: Int64) async -> Int64 {
        guard let token = token.flatMap(LicenseToken.init),
              await verifyLicenseToken(token, publicKeys: publicKeys, verifier: verifier),
              let end = parseISO8601(token.payload.periodEnd)
        else { return received &+ licenseTerminalWaitMs }
        let expiry = end &- (serverTime.flatMap(parseISO8601).map { $0 &- received } ?? 0)
        return expiry > received ? expiry : received &+ licenseTerminalWaitMs
    }
}
