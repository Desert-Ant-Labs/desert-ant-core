// The per-event `context` the ingest accepts: coarse facts about the app and the
// device it runs on, gathered once per process.
//
//   Apple      appVersion, osName, osVersion, deviceModel, formFactor, locale
//   Linux      osName, osVersion (kernel major)
//   Android    osName
//   WASI page  browserName, browserVersion, osName, formFactor, locale
//   WASI Node  osName
//
// A server (platform "server", which includes macOS) and any client whose device
// id the caller or host supplied send only osName, a major-only osVersion and
// appVersion: that device is a tenant's, not the host's, so the host's model and
// locale say nothing about it. A native macOS app is in that set only through its
// platform tag; a Catalyst or iOS-on-Mac app reports "ios" and sends the full set.
//
// The ingest rejects a whole batch whose context is 4096 bytes or more, so every
// context is cut down here (`sanitizeContext`) before it can reach a send.

import JSON

#if canImport(Darwin)
import Darwin
import Foundation
#elseif os(Android)
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(WASI)
import JavaScriptKit
#endif

/// The keys the ingest accepts in an event's `context`. Anything else is dropped.
let contextKeys: Set<String> = [
    "appVersion", "osName", "osVersion", "deviceModel",
    "browserName", "browserVersion", "formFactor", "locale",
]

/// The values the ingest accepts for `formFactor`.
let formFactors: Set<String> = ["desktop", "mobile", "tablet"]

/// Per-value cap. The ingest allows 256 characters; nothing we send needs a
/// quarter of that, so a longer value is a host override gone wrong.
let maxContextValueBytes = 64

/// Cap on the encoded context. Well under the ingest's 4096, so one oversized
/// context can never cost the batch; over it, the event goes without context.
let maxContextBytes = 1024

/// Facts about this process's host, gathered once (`current`).
struct DeviceContext: Sendable, Equatable {
    var appVersion: String?
    var osName: String?
    /// major.minor where the platform has one.
    var osVersion: String?
    var deviceModel: String?
    var browserName: String?
    /// Major only.
    var browserVersion: String?
    var formFactor: String?
    /// language-region, e.g. "pt-BR".
    var locale: String?

    static let current = DeviceContext.detect()

    /// The context sent for this host. `minimal` is the server set.
    func fields(minimal: Bool, appVersionOverride: String? = nil) -> [String: String] {
        var out: [String: String] = [:]
        out["appVersion"] = appVersionOverride ?? appVersion
        out["osName"] = osName
        if minimal {
            out["osVersion"] = osVersion.map(majorVersion)
            return out
        }
        out["osVersion"] = osVersion
        out["deviceModel"] = deviceModel
        out["browserName"] = browserName
        out["browserVersion"] = browserVersion
        out["formFactor"] = formFactor
        out["locale"] = locale
        return out
    }
}

/// The default `context` provider `makeClient` wires. The host facts are cached;
/// the opt-outs and the appVersion override are read per event, so a host that
/// sets them after the first client is built is still honoured.
func defaultContextProvider(platform: String, deviceIdSupplied: Bool) -> () -> [String: String]? {
    let minimal = platform == "server" || deviceIdSupplied
    return {
        if deviceContextDisabled() { return nil }
        return DeviceContext.current.fields(minimal: minimal, appVersionOverride: hostProvidedAppVersion())
    }
}

/// `context` reduced to what the ingest will accept without rejecting the batch:
/// allowlisted keys, printable values of at most `maxContextValueBytes`, a known
/// formFactor, and at most `maxContextBytes` encoded. `nil` when nothing is left
/// or the whole is still too big.
func sanitizeContext(_ context: [String: String]?) -> [String: String]? {
    guard let context else { return nil }
    var out: [String: String] = [:]
    for (key, raw) in context where contextKeys.contains(key) {
        let value = printableValue(raw)
        if value.isEmpty { continue }
        if key == "formFactor" && !formFactors.contains(value) { continue }
        out[key] = value
    }
    if out.isEmpty { return nil }
    guard let json = try? JSONEncoder().encodeToString(out), json.utf8.count <= maxContextBytes else {
        return nil
    }
    return out
}

/// `raw` without control or invisible formatting characters, trimmed, and cut
/// to `maxContextValueBytes` on a character boundary.
func printableValue(_ raw: String) -> String {
    var kept = String.UnicodeScalarView()
    for scalar in raw.unicodeScalars where isPrintable(scalar) { kept.append(scalar) }
    var out = ""
    var bytes = 0
    for character in trimmed(String(kept)) {
        bytes += character.utf8.count
        if bytes > maxContextValueBytes { break }
        out.append(character)
    }
    return trimmed(out)
}

private func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0..<0x20, 0x7F...0x9F: return false            // C0, DEL, C1
    case 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x206F: return false // zero-width, separators, bidi
    case 0xAD, 0x180E, 0xFE00...0xFE0F, 0xFEFF, 0xFFF9...0xFFFB, 0xE0000...0xE007F: return false
    default: return true
    }
}

private func trimmed(_ value: String) -> String {
    String(value.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
}

/// "15.6" -> "15". The server set's coarse version.
func majorVersion(_ version: String) -> String {
    String(version.prefix(while: { $0 != "." }))
}

/// A BCP 47 tag reduced to language and region: "zh-Hant-TW" -> "zh-TW",
/// "en_US" -> "en-US", "fr" -> "fr". `nil` when it does not start with a language.
func languageRegion(_ tag: String?) -> String? {
    guard let tag else { return nil }
    let parts = tag.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "@" || $0 == "." })
    guard let first = parts.first, (2...3).contains(first.count), first.allSatisfy(\.isASCIILetter) else {
        return nil
    }
    let language = first.lowercased()
    for part in parts.dropFirst() {
        if part.count == 2, part.allSatisfy(\.isASCIILetter) { return language + "-" + part.uppercased() }
        if part.count == 3, part.allSatisfy(\.isASCIIDigit) { return language + "-" + part }
        // The region follows the script; an extension or a variant means none came.
        if part.count != 4 { break }
    }
    return language
}

private extension Character {
    var isASCIILetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

// MARK: - Browser

/// The browser vocabulary the dashboard groups by.
let browserNames: Set<String> = ["Chrome", "Edge", "Safari", "Firefox", "Opera", "Samsung Internet", "Other"]

/// Browser name and major version. User-Agent Client Hints first (Chromium
/// browsers), then the user agent string, which is all Safari and Firefox have.
/// A Chromium browser whose brands name none we know (Brave, Vivaldi) is
/// "Other": its user agent string claims Chrome.
func browserIdentity(brands: [(brand: String, version: String)], userAgent: String) -> (name: String, version: String?) {
    let named = brands.filter { !$0.brand.contains("Brand") && $0.brand != "Chromium" }
    if !brands.isEmpty {
        for (prefix, name) in [("Microsoft Edge", "Edge"), ("Opera", "Opera"),
                               ("Samsung Internet", "Samsung Internet"), ("Google Chrome", "Chrome")] {
            if let hit = named.first(where: { $0.brand.hasPrefix(prefix) }) {
                return (name, leadingDigits(hit.version))
            }
        }
        return ("Other", nil)
    }
    for (token, name) in [
        ("SamsungBrowser/", "Samsung Internet"),
        ("OPR/", "Opera"), ("OPiOS/", "Opera"), ("OPT/", "Opera"),
        ("Edg/", "Edge"), ("EdgA/", "Edge"), ("EdgiOS/", "Edge"), ("Edge/", "Edge"),
        ("FxiOS/", "Firefox"), ("Firefox/", "Firefox"),
        ("CriOS/", "Chrome"), ("Chrome/", "Chrome"),
    ] {
        if let version = versionAfter(token, in: userAgent) { return (name, version) }
    }
    if userAgent.contains("Safari/"), let version = versionAfter("Version/", in: userAgent) {
        return ("Safari", version)
    }
    return ("Other", nil)
}

/// The OS a page runs on. Client Hints' platform first, then the user agent.
/// iPadOS 13+ Safari sends a Mac user agent; touch points give it away.
func browserOSName(hintPlatform: String?, userAgent: String, maxTouchPoints: Int) -> String? {
    switch hintPlatform {
    case "Windows": return "Windows"
    case "macOS": return maxTouchPoints > 1 ? "iPadOS" : "macOS"
    case "Linux": return "Linux"
    case "Android": return "Android"
    case "Chrome OS", "ChromeOS": return "ChromeOS"
    case "iOS": return "iOS"
    default: break
    }
    if userAgent.contains("iPad") { return "iPadOS" }
    if userAgent.contains("iPhone") || userAgent.contains("iPod") { return "iOS" }
    if userAgent.contains("Android") { return "Android" }
    if userAgent.contains("CrOS") { return "ChromeOS" }
    if userAgent.contains("Windows") { return "Windows" }
    if userAgent.contains("Macintosh") || userAgent.contains("Mac OS X") {
        return maxTouchPoints > 1 ? "iPadOS" : "macOS"
    }
    if userAgent.contains("Linux") { return "Linux" }
    return nil
}

/// Always one of `formFactors`. An Android user agent without "Mobile" is a
/// tablet by Google's own convention, and a Mac user agent with touch is an iPad.
func browserFormFactor(userAgent: String, mobileHint: Bool?, maxTouchPoints: Int) -> String {
    if userAgent.contains("iPad") { return "tablet" }
    if userAgent.contains("Macintosh") && maxTouchPoints > 1 { return "tablet" }
    if userAgent.contains("iPhone") || userAgent.contains("iPod") { return "mobile" }
    if userAgent.contains("Android") { return userAgent.contains("Mobile") ? "mobile" : "tablet" }
    if mobileHint == true { return "mobile" }
    return "desktop"
}

/// Node's `process.platform` in the vocabulary the other hosts use.
func nodeOSName(_ platform: String?) -> String? {
    switch platform {
    case nil, "": return nil
    case "darwin": return "macOS"
    case "linux": return "Linux"
    case "win32": return "Windows"
    case "android": return "Android"
    case let other?: return other
    }
}

private func versionAfter(_ token: String, in userAgent: String) -> String? {
    guard let range = userAgent.firstRange(of: token) else { return nil }
    return leadingDigits(String(userAgent[range.upperBound...]))
}

private func leadingDigits(_ value: String) -> String? {
    let digits = value.prefix(while: \.isASCIIDigit)
    return digits.isEmpty ? nil : String(digits)
}

// MARK: - Detection

extension DeviceContext {
    static func detect() -> DeviceContext {
#if canImport(Darwin)
        return appleContext()
#elseif os(Linux)
        return DeviceContext(osName: "Linux", osVersion: unameRelease().map(majorMinor))
#elseif os(Android)
        return DeviceContext(osName: "Android")
#elseif os(WASI)
        return jsHostIsNode() ? nodeContext() : browserContext()
#else
        return DeviceContext()
#endif
    }
}

/// "6.8.0-45-generic" -> "6.8".
private func majorMinor(_ version: String) -> String {
    let numeric = version.prefix(while: { $0.isASCIIDigit || $0 == "." })
    return numeric.split(separator: ".").prefix(2).joined(separator: ".")
}

#if os(Linux)
private func unameRelease() -> String? {
    var name = utsname()
    guard uname(&name) == 0 else { return nil }
    return withUnsafeBytes(of: &name.release) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
}
#endif

#if canImport(Darwin)
private func appleContext() -> DeviceContext {
    let info = ProcessInfo.processInfo
    var context = DeviceContext(
        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        locale: currentLocale()
    )
    let version = info.operatingSystemVersion
    let processVersion = "\(version.majorVersion).\(version.minorVersion)"
#if os(macOS)
    context.osName = "macOS"
    context.osVersion = processVersion
    context.deviceModel = sysctlString("hw.model")
    context.formFactor = "desktop"
#elseif os(iOS)
    // Catalyst and iOS apps on a Mac count as macOS: the hardware is a Mac, and
    // their ProcessInfo reports an iOS version number that no Mac ever ran.
    let onMac = info.isMacCatalystApp || info.isiOSAppOnMac
    if onMac {
        context.osName = "macOS"
        context.osVersion = sysctlString("kern.osproductversion").map(majorMinor)
        context.deviceModel = sysctlString("hw.model")
        context.formFactor = "desktop"
    } else {
#if targetEnvironment(simulator)
        let model = info.environment["SIMULATOR_MODEL_IDENTIFIER"]
#else
        let model = machineIdentifier()
#endif
        let iPad = model?.hasPrefix("iPad") == true
        let phone = model.map { $0.hasPrefix("iPhone") || $0.hasPrefix("iPod") } == true
        context.osName = iPad ? "iPadOS" : "iOS"
        context.osVersion = processVersion
        context.deviceModel = model
        context.formFactor = iPad ? "tablet" : phone ? "mobile" : nil
    }
#else
    // tvOS, visionOS, watchOS: none of the three form factors fits.
#if os(tvOS)
    context.osName = "tvOS"
#elseif os(visionOS)
    context.osName = "visionOS"
#elseif os(watchOS)
    context.osName = "watchOS"
#endif
    context.osVersion = processVersion
#if targetEnvironment(simulator)
    context.deviceModel = info.environment["SIMULATOR_MODEL_IDENTIFIER"]
#else
    context.deviceModel = machineIdentifier()
#endif
#endif
    return context
}

private func currentLocale() -> String? {
    guard let language = Locale.current.language.languageCode?.identifier else { return nil }
    return languageRegion(Locale.current.region.map { "\(language)-\($0.identifier)" } ?? language)
}

/// `utsname.machine`, e.g. "iPhone16,2". Read directly rather than through
/// UIDevice, which is MainActor-bound and has no model identifier anyway.
private func machineIdentifier() -> String? {
    var name = utsname()
    guard uname(&name) == 0 else { return nil }
    let value = withUnsafeBytes(of: &name.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    return value.isEmpty ? nil : value
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    let value = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    return value.isEmpty ? nil : value
}
#endif

#if os(WASI)
private func nodeContext() -> DeviceContext {
    DeviceContext(osName: nodeOSName(JSObject.global.process.object?.platform.string))
}

private func browserContext() -> DeviceContext {
    guard let navigator = JSObject.global.navigator.object else { return DeviceContext() }
    let userAgent = navigator.userAgent.string ?? ""
    let touchPoints = Int(navigator.maxTouchPoints.number ?? 0)
    let hints = navigator.userAgentData.object
    var brands: [(brand: String, version: String)] = []
    if let list = hints?.brands.object, let count = list.length.number {
        for index in 0..<Int(count) {
            guard let entry = list[index].object else { continue }
            brands.append((entry.brand.string ?? "", entry.version.string ?? ""))
        }
    }
    let browser = browserIdentity(brands: brands, userAgent: userAgent)
    return DeviceContext(
        osName: browserOSName(hintPlatform: hints?.platform.string, userAgent: userAgent, maxTouchPoints: touchPoints),
        browserName: browser.name,
        browserVersion: browser.version,
        formFactor: browserFormFactor(userAgent: userAgent, mobileHint: hints?.mobile.boolean, maxTouchPoints: touchPoints),
        locale: languageRegion(navigator.language.string)
    )
}
#endif
