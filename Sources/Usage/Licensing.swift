import JSON
import PlatformSupport
#if os(WASI)
import JavaScriptKit
#endif

let defaultLicenseEndpoint = "https://events.desertant.com/api/v1"
let hourMs: Int64 = 60 * 60 * 1000
let dayMs: Int64 = 24 * hourMs
let licenseNetworkRetryMs: Int64 = 5 * 60 * 1000
let licenseMinBackoffMs: Int64 = 60 * 1000
let licenseMaxBackoffMs: Int64 = 6 * hourMs
let licenseTerminalWaitMs: Int64 = dayMs
private let licenseTimeoutSeconds = 10.0

#if os(WASI)
private let licenseKeyInBody = true
#else
private let licenseKeyInBody = false
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
    var activated = false
    var lastFailedGrantAt: Int64?
    var serverOffset: Int64 = 0

    mutating func dropToken() {
        token = nil
        licenseId = nil
        period = nil
        activated = false
    }
}

func licenseStorageKey(_ namespace: String, _ model: String) -> String {
    "ai.desertant.license.\(namespace).\(model)"
}

extension UsageStorage {
    func loadLicense(_ namespace: String, _ model: String) -> StoredLicense {
        get(licenseStorageKey(namespace, model))
            .flatMap { try? JSONDecoder().decode(StoredLicense.self, from: $0) } ?? StoredLicense()
    }

    func saveLicense(_ license: StoredLicense, _ namespace: String, _ model: String) {
        guard let json = try? JSONEncoder().encodeToString(license) else { return }
        set(licenseStorageKey(namespace, model), json)
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
    var key: String?
}

private struct LicenseGrantResponse: Decodable {
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
    private let jitter: @Sendable (Int64) -> Int64
    private let publicKeys: [String: String]
    private let verifier: (any LicenseSignatureVerifier)?
    private let endpoint: @Sendable () -> String
    private let identity: @Sendable () -> LicenseIdentity

    private var running: Set<String> = []
    private var waiting: Set<String> = []
    private var attempts: [String: Int] = [:]
    // Read once: a store that drops writes would otherwise mint a new install, and a new license, per grant.
    private lazy var installId = storage.persistentDeviceId()

    init(
        storage: UsageStorage = defaultStorage(),
        post: @escaping Post = { url, body, headers in
            try await httpPOST(url, body: body, headers: headers, timeout: licenseTimeoutSeconds)
        },
        now: @escaping @Sendable () -> Int64 = systemNowMs,
        schedule: @escaping LicenseScheduler = scheduleLicenseRetry,
        jitter: @escaping @Sendable (Int64) -> Int64 = { Int64.random(in: 0...$0) },
        publicKeys: [String: String] = licensePublicKeys,
        verifier: (any LicenseSignatureVerifier)? = defaultLicenseVerifier(),
        endpoint: @escaping @Sendable () -> String = { hostProvidedLicenseEndpoint() ?? defaultLicenseEndpoint },
        identity: @escaping @Sendable () -> LicenseIdentity = currentLicenseIdentity
    ) {
        self.storage = storage
        self.post = post
        self.now = now
        self.schedule = schedule
        self.jitter = jitter
        self.publicKeys = publicKeys
        self.verifier = verifier
        self.endpoint = endpoint
        self.identity = identity
    }

    func modelLoaded(model: String, modelVersion: String) async {
        let who = identity()
        let slot = who.namespace + "\u{0}" + model
        guard !running.contains(slot), !waiting.contains(slot) else { return }
        running.insert(slot)
        let outcome = await advance(who, model: model, modelVersion: modelVersion)
        running.remove(slot)

        let delay: Int64
        switch outcome {
        case .settled:
            attempts[slot] = nil
            return
        case .network:
            delay = licenseNetworkRetryMs
        case .backoff(let retryAfter):
            let attempt = attempts[slot, default: 0]
            attempts[slot] = attempt + 1
            delay = licenseBackoff(attempt: attempt, retryAfter: retryAfter, jitter: jitter)
        }
        waiting.insert(slot)
        schedule(delay) { await self.retry(slot, model: model, modelVersion: modelVersion) }
    }

    private func retry(_ slot: String, model: String, modelVersion: String) async {
        waiting.remove(slot)
        await modelLoaded(model: model, modelVersion: modelVersion)
    }

    private func advance(_ who: LicenseIdentity, model: String, modelVersion: String) async -> Outcome {
        var license = storage.loadLicense(who.namespace, model)
        let deviceNow = now()
        if let stored = license.token {
            let serverNow = deviceNow &+ license.serverOffset
            if let token = LicenseToken(stored), let end = await verifiedPeriodEnd(token),
               serverNow / 1000 >= token.payload.iat {
                if serverNow < end {
                    if license.activated { return .settled }
                    return await activate(&license, who, model: model)
                }
                // A past month's license that never activated is sent late, then replaced.
                if !license.activated {
                    let outcome = await activate(&license, who, model: model)
                    guard case .settled = outcome else { return outcome }
                }
            }
            license.dropToken()
            storage.saveLicense(license, who.namespace, model)
        }
        if let failedAt = license.lastFailedGrantAt, deviceNow >= failedAt,
           deviceNow &- failedAt < licenseTerminalWaitMs {
            return .settled
        }
        return await grant(&license, who, model: model, modelVersion: modelVersion)
    }

    private func grant(
        _ license: inout StoredLicense, _ who: LicenseIdentity, model: String, modelVersion: String
    ) async -> Outcome {
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
            license.lastFailedGrantAt = received
            storage.saveLicense(license, who.namespace, model)
            return .settled
        case .retry:
            return .backoff(retryAfter: licenseRetryAfter(response))
        case .retryNetwork:
            return .network
        }
        guard let granted = try? JSONDecoder().decode(LicenseGrantResponse.self, from: response.body) else {
            return .backoff(retryAfter: licenseRetryAfter(response))
        }
        if let serverTime = granted.serverTime.flatMap(parseISO8601) {
            license.serverOffset = serverTime &- received
        }
        guard let token = LicenseToken(granted.token), await verifiedPeriodEnd(token) != nil else {
            license.lastFailedGrantAt = received
            storage.saveLicense(license, who.namespace, model)
            return .settled
        }
        license.token = granted.token
        license.licenseId = token.payload.lid
        license.period = token.payload.period
        license.activated = false
        license.lastFailedGrantAt = nil
        storage.saveLicense(license, who.namespace, model)
        return await activate(&license, who, model: model)
    }

    private func verifiedPeriodEnd(_ token: LicenseToken) async -> Int64? {
        guard await verifyLicenseToken(token, publicKeys: publicKeys, verifier: verifier) else { return nil }
        return parseISO8601(token.payload.periodEnd)
    }

    private func activate(_ license: inout StoredLicense, _ who: LicenseIdentity, model: String) async -> Outcome {
        guard let token = license.token else { return .settled }
        let request = LicenseActivateRequest(license: token, key: licenseKeyInBody ? who.apiKey : nil)
        guard let response = await send("activate", request, who) else { return .network }
        let received = now()
        switch licenseResponseAction(status: response.status, body: response.body) {
        case .done:
            guard let result = try? JSONDecoder().decode(LicenseActivateResponse.self, from: response.body),
                  result.activated
            else { return .backoff(retryAfter: licenseRetryAfter(response)) }
            if let serverTime = result.serverTime.flatMap(parseISO8601) {
                license.serverOffset = serverTime &- received
            }
            license.activated = true
        case .terminal:
            license.dropToken()
            license.lastFailedGrantAt = received
        case .retry:
            return .backoff(retryAfter: licenseRetryAfter(response))
        case .retryNetwork:
            return .network
        }
        storage.saveLicense(license, who.namespace, model)
        return .settled
    }

    private func send(_ path: String, _ body: some Encodable, _ who: LicenseIdentity) async -> HTTPResponse? {
        guard let payload = try? JSONEncoder().encode(body) else { return nil }
        var headers: [String: String] = [:]
        if !licenseKeyInBody, let key = who.apiKey { headers["Authorization"] = "Bearer \(key)" }
        var base = endpoint()
        while base.hasSuffix("/") { base.removeLast() }
        return try? await post(base + "/" + path, payload, headers)
    }
}
