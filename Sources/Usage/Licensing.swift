import JSON
import PlatformSupport
#if os(WASI)
import JavaScriptKit
#else
import Dispatch
#endif

let defaultLicenseEndpoint = "https://events.desertant.com/api/v1"
let hourMs: Int64 = 60 * 60 * 1000
let dayMs: Int64 = 24 * hourMs
let licenseNetworkRetryMs: Int64 = 5 * 60 * 1000
let licenseMinBackoffMs: Int64 = 60 * 1000
let licenseMaxBackoffMs: Int64 = 6 * hourMs
let licenseTerminalWaitMs: Int64 = dayMs
let licenseTimeoutSeconds = 10.0

#if os(WASI)
let licenseKeyInBody = true
#else
let licenseKeyInBody = false
#endif

package func licenseOnLoad(_ sdk: SDKInfo) {
    guard let model = sdk.model else { return }
    let modelVersion = sdk.modelVersion ?? ""
    dispatchTracked {
        await LicenseClient.shared.modelLoaded(model: model, modelVersion: modelVersion)
    }
}

struct LicenseIdentity: Sendable, Equatable {
    var appId: String
    var apiKey: String?
    var platform: String
    var namespace: String { apiKey ?? appId }
}

func currentLicenseIdentity() -> LicenseIdentity {
    LicenseIdentity(
        appId: hostProvidedAppId() ?? defaultAppIdentifier(),
        apiKey: hostProvidedApiKey(),
        platform: defaultPlatform)
}

struct StoredLicense: Codable, Equatable {
    var token: String?
    var licenseId: String?
    var period: String?
    var activatedModels: [String]?
    var refusedAt: [String: Int64]?
    var serverOffset: Int64 = 0

    mutating func dropToken() {
        token = nil
        licenseId = nil
        period = nil
        activatedModels = nil
    }

    func isRefused(_ model: String, at time: Int64) -> Bool {
        guard let refused = refusedAt?[model] else { return false }
        return time >= refused && time &- refused < licenseTerminalWaitMs
    }

    mutating func refuse(_ model: String, at time: Int64) {
        refusedAt = (refusedAt ?? [:]).merging([model: time]) { $1 }
    }

    mutating func dropEndedRefusals(at time: Int64) {
        guard let waits = refusedAt?.filter({ isRefused($0.key, at: time) }) else { return }
        refusedAt = waits.isEmpty ? nil : waits
    }
}

extension StoredLicense {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        token = try values.decodeIfPresent(String.self, forKey: .token)
        licenseId = try values.decodeIfPresent(String.self, forKey: .licenseId)
        period = try values.decodeIfPresent(String.self, forKey: .period)
        activatedModels = try values.decodeIfPresent([String].self, forKey: .activatedModels)
        refusedAt = try values.decodeIfPresent([String: Int64].self, forKey: .refusedAt)
        serverOffset = try values.decodeIfPresent(Int64.self, forKey: .serverOffset) ?? 0
    }
}

#if os(WASI)
func withLicenseRecordLock<T>(_ body: () -> T) -> T { body() }
#else
private let licenseRecordLock = DispatchSemaphore(value: 1)

func withLicenseRecordLock<T>(_ body: () -> T) -> T {
    licenseRecordLock.wait()
    defer { licenseRecordLock.signal() }
    return body()
}
#endif

func licenseStorageKey(_ namespace: String) -> String {
    "ai.desertant.license.\(namespace)"
}

extension UsageStorage {
    func loadLicense(_ namespace: String) -> StoredLicense {
        get(licenseStorageKey(namespace))
            .flatMap { try? JSONDecoder().decode(StoredLicense.self, from: $0) } ?? StoredLicense()
    }

    func saveLicense(_ license: StoredLicense, _ namespace: String) {
        guard let json = try? JSONEncoder().encodeToString(license) else { return }
        set(licenseStorageKey(namespace), json)
    }
}

struct LicenseGrantRequest: Encodable {
    var installId: String
    var model: String
    var modelVersion: String
    var sdk: SDKInfo
    var platform: String
    var app: AppInfo
    var key: String?
}

struct LicenseActivateRequest: Encodable {
    var license: String
    var model: String
    var modelVersion: String
    var key: String?
}

struct LicenseGrantResponse: Decodable {
    var token: String
    var serverTime: String?
}

private struct LicenseActivateResponse: Decodable {
    var activated: Bool
    var serverTime: String?
}

private struct LicenseErrorBody: Decodable {
    var error: String
}

enum LicenseResponseAction: String, Equatable {
    case done
    case terminal
    case retry
    case retryNetwork = "retry-network"
}

func licenseResponseAction(status: Int, body: [UInt8]) -> LicenseResponseAction {
    if status == 0 { return .retryNetwork }
    if (200..<300).contains(status) { return .done }
    if status == 400 || status == 422,
       let error = try? JSONDecoder().decode(LicenseErrorBody.self, from: body), !error.error.isEmpty {
        return .terminal
    }
    return .retry
}

func licenseRetryAfter(_ response: HTTPResponse) -> Int64? {
    guard let raw = response.header("Retry-After") else { return nil }
    let parts = raw.split(whereSeparator: \.isWhitespace)
    guard parts.count == 1, let seconds = Int64(parts[0]), seconds >= 0 else { return nil }
    return seconds >= licenseMaxBackoffMs / 1000 ? licenseMaxBackoffMs : seconds * 1000
}

func licenseBackoff(attempt: Int, retryAfter: Int64?, jitter: (Int64) -> Int64) -> Int64 {
    let ceiling = min(licenseMaxBackoffMs, licenseMinBackoffMs << Int64(min(max(attempt, 0), 16)))
    let delay = jitter(ceiling)
    guard let retryAfter else { return delay }
    return min(licenseMaxBackoffMs, max(delay, retryAfter))
}

typealias LicenseScheduler = @Sendable (Int64, @escaping @Sendable () async -> Void) -> Void

func scheduleLicenseRetry(after delay: Int64, _ work: @escaping @Sendable () async -> Void) {
#if os(WASI)
    guard let setTimeout = JSObject.global.setTimeout.function else { return }
    let fire = JSOneshotClosure { _ in
        dispatchTracked(work)
        return .undefined
    }
    let timer = setTimeout(this: JSObject.global, fire, Double(delay))
    // Node: a pending retry must not keep the process alive.
    _ = timer.object?.unref?()
#else
    Task.detached(priority: .utility) {
        try? await Task.sleep(nanoseconds: UInt64(max(delay, 0)) * 1_000_000)
        dispatchTracked(work)
    }
#endif
}

func canScheduleLicenseRetry() -> Bool {
#if os(WASI)
    JSObject.global.setTimeout.function != nil
#else
    true
#endif
}

actor LicenseClient {
    static let shared = LicenseClient()

    typealias Post = @Sendable (String, [UInt8], [String: String]) async throws -> HTTPResponse

    private enum Outcome {
        case settled
        case network
        case backoff(retryAfter: Int64?)
    }

    private let storage: UsageStorage
    private let post: Post
    private let now: @Sendable () -> Int64
    private let schedule: LicenseScheduler
    private let canSchedule: @Sendable () -> Bool
    private let jitter: @Sendable (Int64) -> Int64
    private let publicKeys: [String: String]
    private let verifier: (any LicenseSignatureVerifier)?
    private let endpoint: @Sendable () -> String
    private let identity: @Sendable () -> LicenseIdentity
    private let secret: @Sendable () -> String?

    private var running: Set<String> = []
    private var waiting: Set<String> = []
    private var wanted: [String: [(model: String, version: String)]] = [:]
    private var attempts: [String: Int] = [:]
    private var unsaved: [String: (json: String, stored: String?)] = [:]
    // Kept in memory: a store that drops writes would otherwise make a new install id, and a new license, for each request.
    private lazy var installId = storage.persistentDeviceId()

    init(
        storage: UsageStorage = defaultStorage(),
        post: @escaping Post = { url, body, headers in
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
        secret: @escaping @Sendable () -> String? = { DesertAnt.configuredDeviceIdSecret }
    ) {
        self.storage = storage
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
    }

    func modelLoaded(model: String, modelVersion: String) async {
        let who = identity()
        wanted[who.namespace, default: []].removeAll { $0.model == model }
        wanted[who.namespace, default: []].append((model, modelVersion))
        await work(who)
    }

    private func work(_ who: LicenseIdentity) async {
        let slot = who.namespace
        // A server with a device id secret licenses the devices it serves, and not itself.
        if who.platform == "server", secret() != nil {
            wanted[slot] = nil
            return
        }
        guard !running.contains(slot), !waiting.contains(slot) else { return }
        running.insert(slot)
        var outcome = Outcome.settled
        while case .settled = outcome, let next = wanted[slot]?.first {
            outcome = await advance(who, model: next.model, modelVersion: next.version)
            if case .settled = outcome { wanted[slot]?.removeAll { $0 == next } }
        }
        running.remove(slot)

        let delay: Int64
        switch outcome {
        case .settled:
            return
        case .network:
            delay = licenseNetworkRetryMs
        case .backoff(let retryAfter):
            let attempt = attempts[slot, default: 0]
            attempts[slot] = attempt + 1
            delay = licenseBackoff(attempt: attempt, retryAfter: retryAfter, jitter: jitter)
        }
        guard canSchedule() else { return }
        waiting.insert(slot)
        schedule(delay) { await self.retry(slot) }
    }

    private func retry(_ slot: String) async {
        waiting.remove(slot)
        let who = identity()
        if who.namespace != slot, let moved = wanted.removeValue(forKey: slot) {
            wanted[who.namespace, default: []].append(contentsOf: moved)
            attempts[slot] = nil
        }
        await work(who)
    }

    private func advance(_ who: LicenseIdentity, model: String, modelVersion: String) async -> Outcome {
        while true {
            if load(who).isRefused(model, at: now()) { return .settled }
            var stored = await replaceUnlessValid(who) { _ in }
            if !stored.valid {
                let outcome = await grant(who, model: model, modelVersion: modelVersion)
                guard case .settled = outcome else { return outcome }
                stored = await replaceUnlessValid(who) { _ in }
            }
            guard stored.valid, let token = stored.license.token,
                  stored.license.activatedModels?.contains(model) != true
            else { return .settled }
            if let outcome = await activate(token, who, model: model, modelVersion: modelVersion) { return outcome }
        }
    }

    private func grant(_ who: LicenseIdentity, model: String, modelVersion: String) async -> Outcome {
        if let stored = storage.get(deviceIdKey), !stored.isEmpty { installId = stored }
        let request = LicenseGrantRequest(
            installId: installId,
            model: model,
            modelVersion: modelVersion,
            sdk: SDKInfo(),
            platform: who.platform,
            app: AppInfo(id: who.appId),
            key: licenseKeyInBody ? who.apiKey : nil)
        guard let response = await send("license", request, who) else { return .network }
        let received = now()
        switch licenseResponseAction(status: response.status, body: response.body) {
        case .done:
            break
        case .terminal:
            _ = await replaceUnlessValid(who) { $0.refuse(model, at: received) }
            return .settled
        case .retry:
            return .backoff(retryAfter: licenseRetryAfter(response))
        case .retryNetwork:
            return .network
        }
        guard let granted = try? JSONDecoder().decode(LicenseGrantResponse.self, from: response.body) else {
            return .backoff(retryAfter: licenseRetryAfter(response))
        }
        var candidate = StoredLicense(token: granted.token)
        if let serverTime = granted.serverTime.flatMap(parseISO8601) { candidate.serverOffset = serverTime &- received }
        let usable = await isValid(candidate)
        if usable { attempts[who.namespace] = nil }
        _ = await replaceUnlessValid(who) { license in
            guard usable, let token = LicenseToken(granted.token) else {
                license.refuse(model, at: received)
                return
            }
            license.token = granted.token
            license.licenseId = token.payload.lid
            license.period = token.payload.period
            license.activatedModels = [model]
            license.serverOffset = candidate.serverOffset
            license.refusedAt?[model] = nil
        }
        return .settled
    }

    // Returns nil when the request must be sent again with the token that is stored now.
    private func activate(
        _ token: String, _ who: LicenseIdentity, model: String, modelVersion: String
    ) async -> Outcome? {
        let request = LicenseActivateRequest(
            license: token, model: model, modelVersion: modelVersion, key: licenseKeyInBody ? who.apiKey : nil)
        guard let response = await send("activate", request, who) else { return .network }
        let received = now()
        let action = licenseResponseAction(status: response.status, body: response.body)
        let reply = try? JSONDecoder().decode(LicenseActivateResponse.self, from: response.body)
        if action == .retryNetwork { return .network }
        guard action == .terminal || (action == .done && reply?.activated == true) else {
            return .backoff(retryAfter: licenseRetryAfter(response))
        }
        if action == .done { attempts[who.namespace] = nil }
        return withLicenseRecordLock {
            var license = load(who)
            if action == .terminal {
                if response.status == 422 {
                    guard license.token == token else { return nil }
                    license.dropToken()
                }
                license.refuse(model, at: received)
            } else {
                guard license.token == token else { return nil }
                if license.activatedModels?.contains(model) != true {
                    license.activatedModels = (license.activatedModels ?? []) + [model]
                }
                if let serverTime = reply?.serverTime.flatMap(parseISO8601) {
                    license.serverOffset = serverTime &- received
                }
            }
            save(license, who)
            return .settled
        }
    }

    // Other clients write this record too, so a write starts from what is stored now.
    private func replaceUnlessValid(
        _ who: LicenseIdentity, _ change: (inout StoredLicense) -> Void
    ) async -> (license: StoredLicense, valid: Bool) {
        let key = licenseStorageKey(who.namespace)
        while true {
            let raw = read(key)
            let stored = load(who)
            if await isValid(stored) { return (stored, true) }
            var license = stored
            license.dropToken()
            change(&license)
            license.dropEndedRefusals(at: now())
            let saved: StoredLicense? = withLicenseRecordLock {
                guard read(key) == raw else { return nil }
                if license != stored { save(license, who) }
                return license
            }
            if let saved { return (saved, false) }
        }
    }

    // The copy in memory serves only while the store holds what it held when the write failed.
    private func read(_ key: String) -> String? {
        let kept = storage.get(key)
        guard let copy = unsaved[key] else { return kept }
        if kept == copy.stored { return copy.json }
        unsaved[key] = nil
        return kept
    }

    private func load(_ who: LicenseIdentity) -> StoredLicense {
        read(licenseStorageKey(who.namespace))
            .flatMap { try? JSONDecoder().decode(StoredLicense.self, from: $0) } ?? StoredLicense()
    }

    private func save(_ license: StoredLicense, _ who: LicenseIdentity) {
        var license = license
        license.dropEndedRefusals(at: now())
        guard let json = try? JSONEncoder().encodeToString(license) else { return }
        let key = licenseStorageKey(who.namespace)
        storage.set(key, json)
        let kept = storage.get(key)
        unsaved[key] = kept == json ? nil : (json, kept)
    }

    private func isValid(_ license: StoredLicense) async -> Bool {
        guard let token = license.token.flatMap(LicenseToken.init), let end = await verifiedPeriodEnd(token) else {
            return false
        }
        let serverNow = now() &+ license.serverOffset
        return serverNow / 1000 >= token.payload.iat && serverNow < end
    }

    private func verifiedPeriodEnd(_ token: LicenseToken) async -> Int64? {
        guard await verifyLicenseToken(token, publicKeys: publicKeys, verifier: verifier) else { return nil }
        return parseISO8601(token.payload.periodEnd)
    }

    private func send(_ path: String, _ body: some Encodable, _ who: LicenseIdentity) async -> HTTPResponse? {
        guard let payload = try? JSONEncoder().encode(body) else { return nil }
        return await postLicenseRequest(path, payload, apiKey: who.apiKey, endpoint: endpoint(), post: post)
    }
}

func postLicenseRequest(
    _ path: String, _ payload: [UInt8], apiKey: String?, endpoint: String, post: LicenseClient.Post
) async -> HTTPResponse? {
    var headers: [String: String] = [:]
    if !licenseKeyInBody, let apiKey { headers["Authorization"] = "Bearer \(apiKey)" }
    var base = endpoint
    while base.hasSuffix("/") { base.removeLast() }
    return try? await post(base + "/" + path, payload, headers)
}
