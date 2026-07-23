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

/// SDK identity attached to every body's `sdk` field.
public let defaultSDKName = "desert-ant-core"
public let defaultSDKVersion = "0.1.0" // keep in sync with the package/product version

/// The platform tag put on the wire's `platform` field, derived from the build
/// target. `IngestBody` defaults to this, so callers never pass it by hand.
#if os(Android)
public let defaultPlatform = "android"
#elseif os(iOS)
public let defaultPlatform = "ios"
#elseif os(macOS)
public let defaultPlatform = "macos"
#elseif os(tvOS)
public let defaultPlatform = "tvos"
#elseif os(visionOS)
public let defaultPlatform = "visionos"
#elseif os(watchOS)
public let defaultPlatform = "watchos"
#elseif os(Linux)
public let defaultPlatform = "linux"
#elseif os(WASI)
public let defaultPlatform = "web"
#else
public let defaultPlatform = "unknown"
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
public struct IngestEvent: Codable, Sendable, Equatable {
    public var name: String
    public var deviceId: String
    public var callCount: Int?
    public var timestamp: String?
    public var context: [String: String]?

    public init(
        name: String = "load",
        deviceId: String,
        callCount: Int? = nil,
        timestamp: String? = nil,
        context: [String: String]? = nil
    ) {
        self.name = name
        self.deviceId = deviceId
        self.callCount = callCount
        self.timestamp = timestamp
        self.context = context
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

/// The request body posted to the ingest endpoint. Attribution is either a
/// publishable `key` or — keyless, off-browser — the app identity in `app`.
/// Field order on the wire follows declaration order.
public struct IngestBody: Codable, Sendable, Equatable {
    public var platform: String
    public var key: String?
    public var app: AppInfo?
    public var sdk: SDKInfo
    public var sentAt: String
    public var events: [IngestEvent]

    public init(
        platform: String = defaultPlatform,
        key: String? = nil,
        app: AppInfo? = nil,
        sdk: SDKInfo = SDKInfo(),
        sentAt: String,
        events: [IngestEvent]
    ) {
        self.platform = platform
        self.key = key
        self.app = app
        self.sdk = sdk
        self.sentAt = sentAt
        self.events = events
    }
}

/// Serialize a body to the exact JSON the ingest endpoint expects. The key rides
/// the body (never a header) so hosts that POST it stay a CORS "simple" request.
public func buildBody(_ body: IngestBody) throws -> String {
    try JSONEncoder().encodeToString(body)
}
