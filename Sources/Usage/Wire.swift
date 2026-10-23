#if os(WASI)
import JavaScriptKit
#endif

/// The `sdk` a license grant names: the package itself, at the version in
/// `VERSION`. `mise run set-version` rewrites it and `check:version` holds it.
public let defaultSDKName = "desert-ant-core"
public let defaultSDKVersion = "4.2.0"

/// The platform tag put on the wire's `platform` field, derived from the build
/// target.
///
/// The license API accepts exactly `ios | android | web | server`, so the build
/// targets are mapped onto those: Apple device platforms (iPhone, TV, watch,
/// Vision) report `ios`, and everything that runs on a desktop or a server
/// (macOS, Linux, Node-native hosts) reports `server`. The wasm build serves
/// two hosts from one binary (a browser page and Node, e.g. an SSR pass), so
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

/// SDK identity block.
public struct SDKInfo: Codable, Sendable, Equatable {
    public var name: String
    public var version: String
    // A grant sends these as its own fields; `sdk` on the wire is name and version only.
    package var model: String? = nil
    package var modelVersion: String? = nil

    public init(name: String = defaultSDKName, version: String = defaultSDKVersion) {
        self.name = name
        self.version = version
    }

    package init(name: String, version: String, model: String, modelVersion: String) {
        self.name = name
        self.version = version
        self.model = model
        self.modelVersion = modelVersion
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case version
    }
}

/// App identity for a license grant. Native platforms have no browser
/// `Origin`, so they identify by `app.id` (the platform app identifier: bundle
/// id on Apple, package name on Android, etc.), sent as a nested
/// `{"app":{"id":"..."}}`.
public struct AppInfo: Codable, Sendable, Equatable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}
