// Wire format for the usage turnstile — a native port of desert-ant-web's core.
//
// The one billed signal is a `load` event. The server dedups by device
// (COUNT DISTINCT deviceId per company per month) and SUMS callCount across
// events, so emitting an extra `load` never over-bills and a session's calls
// can be split across several events and still add up.
//
// The types are `Codable`; serialization goes through the `JSON` module's
// `JSONEncoder` (Foundation-backed on Apple/Linux, a native tree encoder on
// Android/wasm), so no JSON is hand-written here.

import JSON
#if os(WASI)
import JavaScriptKit
#endif

/// SDK identity attached to every body's `sdk` field.
public let defaultSDKName = "desert-ant-core"
public let defaultSDKVersion = "0.1.0" // keep in sync with the package/product version

/// The platform tag put on the wire's `platform` field, derived from the build
/// target. `IngestBody` defaults to this, so callers never pass it by hand.
///
/// The ingest API accepts exactly `ios | android | web | server`, so the build
/// targets are mapped onto those: Apple device platforms (iPhone, TV, watch,
/// Vision) report `ios`, and everything that runs on a desktop or a server
/// (macOS, Linux, Node-native hosts) reports `server`. The wasm build serves
/// two hosts from one binary — a browser page and Node (e.g. an SSR pass) — so
/// on WASI the tag is detected at runtime: a browser is `web`, Node is `server`.
#if os(Android)
public let defaultPlatform = "android"
#elseif os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
public let defaultPlatform = "ios"
#elseif os(WASI)
public var defaultPlatform: String {
    // Node exposes `process.versions.node`; no browser global does. Checked
    // rather than `location` so an SSR framework that shims `location` (or a
    // browser extension page without one) still classifies correctly.
    if JSObject.global.process.object?.versions.object?.node.string != nil {
        return "server"
    }
    return "web"
}
#else
public let defaultPlatform = "server"
#endif

/// SDK identity block. Optional fields on the wire are omitted when `nil`
/// (Codable synthesizes `encodeIfPresent` for optionals).
public struct SDKInfo: Codable, Sendable, Equatable {
    public var name: String
    public var version: String

    public init(name: String = defaultSDKName, version: String = defaultSDKVersion) {
        self.name = name
        self.version = version
    }
}

/// A single ingest event. `name` is always `"load"`; the optional fields are
/// omitted from the wire when unset.
///
/// `sessionId` (schema 2) identifies the client session the event belongs to —
/// one id per `UsageClient` lifetime, shared by the turnstile and every delta it
/// emits. It is what makes session length / frequency representable server-side;
/// without it one device with 50 deltas in a session is indistinguishable from
/// one device with 50 sessions. Additive: old servers ignore it.
public struct IngestEvent: Codable, Sendable, Equatable {
    public var name: String
    public var deviceId: String
    public var callCount: Int?
    public var timestamp: String?
    public var context: [String: String]?
    public var sessionId: String?

    public init(
        name: String = "load",
        deviceId: String,
        callCount: Int? = nil,
        timestamp: String? = nil,
        context: [String: String]? = nil,
        sessionId: String? = nil
    ) {
        self.name = name
        self.deviceId = deviceId
        self.callCount = callCount
        self.timestamp = timestamp
        self.context = context
        self.sessionId = sessionId
    }
}

/// App identity for keyless attribution. Native platforms have no browser
/// `Origin`, so they identify by `app.id` (the platform app identifier — bundle
/// id on Apple, package name on Android, etc.). Rides the body as a nested
/// `{"app":{"id":"..."}}`.
public struct AppInfo: Codable, Sendable, Equatable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

/// Wire schema version this SDK emits. 1 = the original body; 2 adds
/// `batchId`, `schemaVersion` and per-event `sessionId` (all additive).
public let wireSchemaVersion = 2

/// The request body posted to the ingest endpoint. Attribution is either a
/// publishable `key` or — keyless, off-browser — the app identity in `app`.
/// Field order on the wire follows declaration order.
///
/// `batchId` (schema 2) is minted once per body. It is the delivery contract:
/// a server can de-duplicate on (batchId, event index) whatever sits between
/// this SDK and its store, so a retry or a replay can never double-count —
/// without any further SDK change. There is no retry in this SDK yet; when one
/// ships it MUST resend the same body with the same batchId.
public struct IngestBody: Codable, Sendable, Equatable {
    public var platform: String
    public var key: String?
    public var app: AppInfo?
    public var sdk: SDKInfo
    public var sentAt: String
    public var events: [IngestEvent]
    public var batchId: String?
    public var schemaVersion: Int?

    public init(
        platform: String = defaultPlatform,
        key: String? = nil,
        app: AppInfo? = nil,
        sdk: SDKInfo = SDKInfo(),
        sentAt: String,
        events: [IngestEvent],
        batchId: String? = nil,
        schemaVersion: Int? = nil
    ) {
        self.platform = platform
        self.key = key
        self.app = app
        self.sdk = sdk
        self.sentAt = sentAt
        self.events = events
        self.batchId = batchId
        self.schemaVersion = schemaVersion
    }
}

/// Serialize a body to the exact JSON the ingest endpoint expects. The key rides
/// the body (never a header) so hosts that POST it stay a CORS "simple" request.
public func buildBody(_ body: IngestBody) throws -> String {
    try JSONEncoder().encodeToString(body)
}
