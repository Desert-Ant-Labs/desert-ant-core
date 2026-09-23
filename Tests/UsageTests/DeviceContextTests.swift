import Testing
@testable import Usage
import JSON
#if os(WASI)
import JavaScriptKit
#endif

private let serverSet: Set<String> = ["appVersion", "osName", "osVersion"]

private let everyField = DeviceContext(
    appVersion: "3.1.0",
    osName: "iOS",
    osVersion: "18.2",
    deviceModel: "iPhone16,2",
    browserName: "Safari",
    browserVersion: "18",
    formFactor: "mobile",
    locale: "pt-BR"
)

private func encodedSize(_ context: [String: String]) -> Int {
    (try? JSONEncoder().encodeToString(context))?.utf8.count ?? .max
}

struct ContextSanitizingTests {
    @Test func onlyTheAllowlistedKeysSurvive() {
        let context = sanitizeContext([
            "osName": "iOS", "deviceName": "Ana's iPhone", "email": "a@b.c", "locale": "pt-BR",
        ])
        #expect(context == ["osName": "iOS", "locale": "pt-BR"])
    }

    @Test func aFormFactorOutsideTheVocabularyIsDropped() {
        #expect(sanitizeContext(["formFactor": "tv", "osName": "tvOS"]) == ["osName": "tvOS"])
        for value in formFactors {
            #expect(sanitizeContext(["formFactor": value])?["formFactor"] == value)
        }
    }

    @Test func valuesArePrintableTrimmedAndCut() {
        #expect(printableValue("  \u{7}ab\u{202E}c\u{AD}\u{FE0F}\u{E0041}\n\t ") == "abc")
        let long = printableValue(String(repeating: "é", count: 100))   // 2 bytes each
        #expect(long.utf8.count == maxContextValueBytes)
        // Never splits a character to fit: 3-byte characters stop at 63 bytes.
        #expect(printableValue(String(repeating: "語", count: 100)).utf8.count == 63)
    }

    @Test func nothingLeftIsNoContext() {
        #expect(sanitizeContext(nil) == nil)
        #expect(sanitizeContext([:]) == nil)
        #expect(sanitizeContext(["osName": " \u{0} ", "other": "x"]) == nil)
    }

    /// Eight values of nothing but quotes escape to twice their length, past the
    /// cap. The context goes; the event does not.
    @Test func anOversizedContextIsDroppedAndTheEventStillSent() {
        let quotes = String(repeating: "\"", count: maxContextValueBytes)
        let oversized = Dictionary(uniqueKeysWithValues: contextKeys.map { ($0, quotes) })
            .merging(["formFactor": "mobile"]) { $1 }
        #expect(sanitizeContext(oversized) == nil)

        var sent: [IngestBody] = []
        let client = UsageClient(ClientDeps(
            deviceId: "d",
            platform: "test",
            context: { oversized },
            loadState: { UsageState() },
            saveState: { _ in },
            send: { body, _ in sent.append(body) }
        ))
        client.start()
        client.flush()
        #expect(sent.count == 1)
        #expect(sent[0].events[0].context == nil)
    }

    @Test func anOversizedAppVersionOverrideIsCutNotSentWhole() throws {
        let override = String(repeating: "9", count: 10_000)
        let context = try #require(sanitizeContext(everyField.fields(minimal: false, appVersionOverride: override)))
        #expect(context["appVersion"]?.utf8.count == maxContextValueBytes)
        #expect(context["osName"] == "iOS")
        #expect(encodedSize(context) <= maxContextBytes)
    }

    /// Whatever the host facts, the largest context a provider can build fits.
    @Test func theLargestPossibleContextFits() throws {
        let widest = String(repeating: "\u{10FFFF}", count: 100)
        let facts = DeviceContext(
            appVersion: widest, osName: widest, osVersion: widest, deviceModel: widest,
            browserName: widest, browserVersion: widest, formFactor: "tablet", locale: widest
        )
        let context = try #require(sanitizeContext(facts.fields(minimal: false)))
        #expect(context.count == 8)
        #expect(encodedSize(context) <= maxContextBytes)
    }
}

struct ContextFieldsTests {
    @Test func theServerSetIsOSAndAppVersionWithAMajorOnlyVersion() {
        let context = everyField.fields(minimal: true)
        #expect(Set(context.keys) == serverSet)
        #expect(context["osVersion"] == "18")
    }

    @Test func theFullSetCarriesEveryFact() {
        let context = everyField.fields(minimal: false)
        #expect(Set(context.keys) == contextKeys)
        #expect(context["osVersion"] == "18.2")
    }

    @Test func anAppVersionOverrideWins() {
        #expect(everyField.fields(minimal: true, appVersionOverride: "9.9")["appVersion"] == "9.9")
        #expect(DeviceContext(osName: "Linux").fields(minimal: true, appVersionOverride: "1.0")
            == ["osName": "Linux", "appVersion": "1.0"])
    }

    @Test func majorVersions() {
        #expect(majorVersion("15.6") == "15")
        #expect(majorVersion("26") == "26")
    }

    @Test func localesAreLanguageAndRegionOnly() {
        #expect(languageRegion("pt-BR") == "pt-BR")
        #expect(languageRegion("en_US") == "en-US")
        #expect(languageRegion("zh-Hant-TW") == "zh-TW")
        #expect(languageRegion("es-419") == "es-419")
        #expect(languageRegion("fr") == "fr")
        #expect(languageRegion("de-DE-u-co-phonebk") == "de-DE")
        #expect(languageRegion("en-US@rg=gbzzzz") == "en-US")
        #expect(languageRegion("sr-Latn") == "sr")
        #expect(languageRegion("") == nil)
        #expect(languageRegion("*") == nil)
        #expect(languageRegion(nil) == nil)
    }

    @Test func nodePlatformsMapOntoTheSameOSNames() {
        #expect(nodeOSName("darwin") == "macOS")
        #expect(nodeOSName("linux") == "Linux")
        #expect(nodeOSName("win32") == "Windows")
        #expect(nodeOSName("freebsd") == "freebsd")
        #expect(nodeOSName(nil) == nil)
    }

    @Test func flagTruthiness() {
        for value in ["1", "true", "yes", "TRUE"] { #expect(flagIsSet(value)) }
        for value: String? in [nil, "", "0", "false"] { #expect(!flagIsSet(value)) }
    }
}

/// The facts Kotlin's `HostBridge.deviceContext` hands the Android core.
struct AndroidHostContextTests {
    private let lines = """
        osName=Android
        appVersion=2.4.1
        osVersion=14
        deviceModel=Pixel 8 Pro
        formFactor=mobile
        locale=pt-BR
        """

    @Test func everyFactTheBridgeSendsIsRead() {
        #expect(hostDeviceContext(lines) == DeviceContext(
            appVersion: "2.4.1", osName: "Android", osVersion: "14",
            deviceModel: "Pixel 8 Pro", formFactor: "mobile", locale: "pt-BR"
        ))
    }

    @Test func aHostWithNothingStillSendsTheOS() {
        #expect(hostDeviceContext("") == DeviceContext(osName: "Android"))
        #expect(hostDeviceContext("\n\n").fields(minimal: false) == ["osName": "Android"])
    }

    @Test func unknownKeysEmptyValuesAndStrayLinesAreSkipped() {
        let context = hostDeviceContext("serial=R58M123\nlocale=\ngarbage\r\ndeviceModel=a=b\nosName=Linux")
        #expect(context == DeviceContext(osName: "Android", deviceModel: "a=b"))
    }

    @Test func theLocaleIsCutToLanguageAndRegion() {
        #expect(hostDeviceContext("locale=zh-Hant-TW").locale == "zh-TW")
        #expect(hostDeviceContext("locale=*").locale == nil)
    }

    /// A supplied device id (or a server tag) drops the model, form factor and
    /// locale on Android too, and cuts the version to its major.
    @Test func theMinimalSetHoldsForAnAndroidHost() {
        let context = hostDeviceContext(lines).fields(minimal: true)
        #expect(context == ["appVersion": "2.4.1", "osName": "Android", "osVersion": "14"])
        #expect(hostDeviceContext("osVersion=8.1").fields(minimal: true)["osVersion"] == "8")
    }

    @Test func anOversizedModelIsCutByTheSanitizer() {
        let model = String(repeating: "M", count: 300)
        let context = sanitizeContext(hostDeviceContext("deviceModel=\(model)\nformFactor=phablet").fields(minimal: false))
        #expect(context?["deviceModel"]?.utf8.count == maxContextValueBytes)
        #expect(context?["formFactor"] == nil)
    }
}

/// One row of the browser vocabulary: what a page reports, and what we send.
private struct BrowserCase: CustomTestStringConvertible, Sendable {
    let label: String
    var brands: [String: String] = [:]
    var hintPlatform: String?
    var mobileHint: Bool?
    let userAgent: String
    var touch = 0
    let name: String
    let version: String?
    let os: String?
    let form: String
    var testDescription: String { label }

    var brandList: [(brand: String, version: String)] {
        brands.sorted { $0.key < $1.key }.map { (brand: $0.key, version: $0.value) }
    }
}

private let chromeMacUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
private let chromeWinUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

private let browserCases: [BrowserCase] = [
    BrowserCase(label: "Chrome on macOS",
                brands: ["Google Chrome": "131", "Chromium": "131", "Not_A Brand": "24"],
                hintPlatform: "macOS", mobileHint: false, userAgent: chromeMacUA,
                name: "Chrome", version: "131", os: "macOS", form: "desktop"),
    BrowserCase(label: "Edge on Windows",
                brands: ["Microsoft Edge": "131", "Chromium": "131", "Not_A Brand": "24"],
                hintPlatform: "Windows", mobileHint: false,
                userAgent: chromeWinUA + " Edg/131.0.0.0",
                name: "Edge", version: "131", os: "Windows", form: "desktop"),
    BrowserCase(label: "Opera on Windows",
                brands: ["Opera": "115", "Chromium": "130", "Not?A_Brand": "99"],
                hintPlatform: "Windows", mobileHint: false,
                userAgent: chromeWinUA + " OPR/115.0.0.0",
                name: "Opera", version: "115", os: "Windows", form: "desktop"),
    BrowserCase(label: "Brave (brands name no browser we know)",
                brands: ["Brave": "131", "Chromium": "131", "Not_A Brand": "24"],
                hintPlatform: "Windows", mobileHint: false, userAgent: chromeWinUA,
                name: "Other", version: nil, os: "Windows", form: "desktop"),
    BrowserCase(label: "Samsung Internet on an Android phone",
                brands: ["Samsung Internet": "27", "Chromium": "125", "Not.A/Brand": "24"],
                hintPlatform: "Android", mobileHint: true,
                userAgent: "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/27.0 Chrome/125.0.0.0 Mobile Safari/537.36",
                name: "Samsung Internet", version: "27", os: "Android", form: "mobile"),
    BrowserCase(label: "Chrome on an Android tablet",
                brands: ["Google Chrome": "131", "Chromium": "131", "Not_A Brand": "24"],
                hintPlatform: "Android", mobileHint: false,
                userAgent: "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
                name: "Chrome", version: "131", os: "Android", form: "tablet"),
    BrowserCase(label: "Chrome on ChromeOS",
                brands: ["Google Chrome": "131", "Chromium": "131", "Not_A Brand": "24"],
                hintPlatform: "Chrome OS", mobileHint: false,
                userAgent: "Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
                name: "Chrome", version: "131", os: "ChromeOS", form: "desktop"),
    BrowserCase(label: "Safari on macOS",
                userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15",
                name: "Safari", version: "18", os: "macOS", form: "desktop"),
    BrowserCase(label: "Safari on an iPad (desktop user agent, touch)",
                userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15",
                touch: 5,
                name: "Safari", version: "18", os: "iPadOS", form: "tablet"),
    BrowserCase(label: "Safari on an iPhone",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1",
                touch: 5,
                name: "Safari", version: "18", os: "iOS", form: "mobile"),
    BrowserCase(label: "Chrome on an iPhone",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/131.0.6778.73 Mobile/15E148 Safari/604.1",
                touch: 5,
                name: "Chrome", version: "131", os: "iOS", form: "mobile"),
    BrowserCase(label: "Firefox on Linux",
                userAgent: "Mozilla/5.0 (X11; Linux x86_64; rv:133.0) Gecko/20100101 Firefox/133.0",
                name: "Firefox", version: "133", os: "Linux", form: "desktop"),
    BrowserCase(label: "Firefox on an Android phone",
                userAgent: "Mozilla/5.0 (Android 14; Mobile; rv:133.0) Gecko/133.0 Firefox/133.0",
                name: "Firefox", version: "133", os: "Android", form: "mobile"),
    BrowserCase(label: "Firefox on Windows",
                userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0",
                name: "Firefox", version: "133", os: "Windows", form: "desktop"),
    BrowserCase(label: "An iOS in-app web view",
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                touch: 5,
                name: "Other", version: nil, os: "iOS", form: "mobile"),
    BrowserCase(label: "Nothing to go on",
                userAgent: "",
                name: "Other", version: nil, os: nil, form: "desktop"),
]

struct BrowserVocabularyTests {
    @Test(arguments: browserCases)
    fileprivate func aPageIsDescribedInTheSharedVocabulary(_ row: BrowserCase) {
        let browser = browserIdentity(brands: row.brandList, userAgent: row.userAgent)
        #expect(browser.name == row.name)
        #expect(browser.version == row.version)
        #expect(browserNames.contains(browser.name))
        #expect(browserOSName(hintPlatform: row.hintPlatform, userAgent: row.userAgent, maxTouchPoints: row.touch) == row.os)
        #expect(browserFormFactor(userAgent: row.userAgent, mobileHint: row.mobileHint, maxTouchPoints: row.touch) == row.form)
    }

    /// Whatever a page reports, the form factor is one the ingest accepts:
    /// anything else would be dropped, and the dashboard would lose the device.
    @Test func theFormFactorIsAlwaysOneTheIngestAccepts() {
        let agents = browserCases.map(\.userAgent) + [
            "curl/8.4.0", "Mozilla/5.0 (PlayStation; PlayStation 5/2.26)", "Android", "iPad", "Mobile",
            "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0)", "\u{0}", String(repeating: "Macintosh ", count: 50),
        ]
        for userAgent in agents {
            for touch in [0, 1, 5] {
                for hint: Bool? in [nil, false, true] {
                    #expect(formFactors.contains(browserFormFactor(userAgent: userAgent, mobileHint: hint, maxTouchPoints: touch)))
                }
            }
        }
    }
}

// Serialized: `DesertAnt.sendsDeviceContext` is process-wide, and these read the
// real provider, which honours it. A test elsewhere that relies on the default
// provider would race `theInCodeOptOutSendsUsageWithoutContext`; inject one.
@Suite(.serialized) struct DefaultContextProviderTests {
    private func firstContext(
        platform: String, deviceId: String? = nil, storage: InMemoryStorage = InMemoryStorage()
    ) -> [String: String]? {
        var sent: [IngestBody] = []
        let client = makeClient(
            appId: "co.acme.app",
            deviceId: deviceId,
            platform: platform,
            storage: storage,
            send: { body, _ in sent.append(body) },
            disabled: { false }
        )
        client.start()
        client.flush()
        return sent.first?.events.first?.context
    }

    @Test(.enabled(if: !deviceContextDisabled()))
    func aServerSendsOnlyTheServerSet() throws {
        let context = try #require(firstContext(platform: "server"))
        #expect(Set(context.keys).isSubset(of: serverSet))
        #expect(context["osName"] != nil)
        if let version = context["osVersion"] { #expect(!version.contains(".")) }
    }

    /// A device id the caller supplied is a tenant's device, not this host.
    @Test(.enabled(if: !deviceContextDisabled()))
    func aSuppliedDeviceIdGetsOnlyTheServerSet() throws {
        let context = try #require(firstContext(platform: "ios", deviceId: "tenant-device"))
        #expect(Set(context.keys).isSubset(of: serverSet))
        #expect(context["osName"] != nil)
    }

    /// Inference passes the persisted id explicitly on every default path, so an
    /// explicit id equal to it is this device's own and gets the full set. On
    /// WASI and Android the full set is the server set, so there the check is
    /// structural only.
    @Test(.enabled(if: hostProvidedDeviceId() == nil && !deviceContextDisabled()))
    func thePersistedIdPassedExplicitlyGetsTheFullSet() throws {
        let store = InMemoryStorage()
        let id = store.persistentDeviceId()
        let context = try #require(firstContext(platform: "ios", deviceId: id, storage: store))
        #expect(context == firstContext(platform: "ios"))
        #if canImport(Darwin)
        #expect(context["deviceModel"] != nil)
        #elseif os(Linux)
        #expect(context["osVersion"]?.contains(".") == true)
        #endif
    }

    // A shell with DAL_DEVICE_ID or the context flag set changes the answer.
    @Test(.enabled(if: hostProvidedDeviceId() == nil && !deviceContextDisabled()))
    func aGeneratedDeviceIdOnADeviceGetsTheFullSet() {
        let context = firstContext(platform: "ios")
        #expect(context == sanitizeContext(DeviceContext.current.fields(minimal: false, appVersionOverride: hostProvidedAppVersion())))
        #if canImport(Darwin)
        // Apple hosts always know their model and form factor.
        #expect(context?["deviceModel"] != nil)
        #expect(context?["formFactor"].map(formFactors.contains) == true)
        #endif
    }

    /// Caller-passed context goes through the same cut as the provider's.
    // Here, not with the other sanitizing tests: it reads the process-wide opt-out.
    @Test(.enabled(if: !deviceContextDisabled()))
    func anExplicitLoadContextIsSanitizedToo() {
        var sent: [IngestBody] = []
        let client = UsageClient(ClientDeps(
            deviceId: "d", platform: "test",
            context: { ["osName": "Linux"] },
            loadState: { UsageState() }, saveState: { _ in },
            send: { body, _ in sent.append(body) }
        ))
        client.load(context: ["osName": "macOS", "hostname": "build-07"])
        #expect(sent.first?.events.first?.context == ["osName": "macOS"])
    }

    @Test func anExplicitLoadContextObeysTheOptOut() {
        DesertAnt.sendsDeviceContext = false
        defer { DesertAnt.sendsDeviceContext = true }
        var sent: [IngestBody] = []
        let client = UsageClient(ClientDeps(
            deviceId: "d", platform: "test",
            loadState: { UsageState() }, saveState: { _ in },
            send: { body, _ in sent.append(body) }
        ))
        client.load(context: ["osName": "macOS"])
        #expect(sent.count == 1)
        #expect(sent[0].events[0].context == nil)
    }

    @Test func aCallersOwnProviderObeysTheOptOut() {
        DesertAnt.sendsDeviceContext = false
        defer { DesertAnt.sendsDeviceContext = true }
        var sent: [IngestBody] = []
        let client = UsageClient(ClientDeps(
            deviceId: "d", platform: "test",
            context: { ["osName": "Linux"] },
            loadState: { UsageState() }, saveState: { _ in },
            send: { body, _ in sent.append(body) }
        ))
        client.start()
        client.flush()
        #expect(sent.count == 1)
        #expect(sent[0].events[0].context == nil)
    }

    @Test func anOptOutSetBeforeTheFlushDropsTheQueuedContext() {
        defer { DesertAnt.sendsDeviceContext = true }
        var sent: [IngestBody] = []
        let client = UsageClient(ClientDeps(
            deviceId: "d", platform: "test",
            context: { ["osName": "Linux"] },
            loadState: { UsageState() }, saveState: { _ in },
            send: { body, _ in sent.append(body) }
        ))
        client.start()
        DesertAnt.sendsDeviceContext = false
        client.flush()
        #expect(sent.count == 1)
        #expect(sent[0].events[0].context == nil)
    }

    @Test func theInCodeOptOutSendsUsageWithoutContext() {
        DesertAnt.sendsDeviceContext = false
        defer { DesertAnt.sendsDeviceContext = true }
        #expect(deviceContextDisabled())
        var sent: [IngestBody] = []
        let client = makeClient(appId: "co.acme.app", platform: "ios", storage: InMemoryStorage(), send: { body, _ in sent.append(body) }, disabled: { false })
        client.start()
        client.flush()
        #expect(sent.count == 1)
        #expect(sent[0].events[0].context == nil)
    }

    @Test func onByDefault() {
        #expect(DesertAnt.sendsDeviceContext)
    }

    #if os(WASI)
    /// test:wasi runs under Node: the host facts are process.platform only.
    @Test func underNodeTheOSComesFromProcessPlatform() {
        let platform = JSObject.global.process.object?.platform.string
        #expect(DeviceContext.current.osName == nodeOSName(platform))
        #expect(DeviceContext.current.browserName == nil)
    }

    /// A store whose calls throw (a full origin, a host store's I/O error) costs
    /// the stored state, never the event already taken off the queue.
    @Test func aThrowingStoreStillSendsTheTurnstile() throws {
        let throwing = JSObject.global.Function.function!.new("k", "v", "throw new Error('quota')")
        let object = JSObject.global.Object.function!.new()
        object.getItem = .object(throwing)
        object.setItem = .object(throwing)
        let store = JSKeyValueStorage(object: object)
        #expect(store.get("k") == nil)
        store.set("k", "v")
        var sent: [IngestBody] = []
        let client = makeClient(
            appId: "co.acme.app", deviceId: "d", platform: "web", context: { nil },
            storage: store, send: { body, _ in sent.append(body) }, disabled: { false }
        )
        client.start()
        client.flush()
        #expect(sent.count == 1)
    }

    /// A store shaped like localStorage, whose methods need their `this`.
    @Test func aJSStoreRoundTrips() {
        let make = JSObject.global.Function.function!.new("""
            return { m: new Map(),
                     getItem(k) { return this.m.has(k) ? this.m.get(k) : null },
                     setItem(k, v) { this.m.set(k, String(v)) } }
            """)
        let store = JSKeyValueStorage(object: make().object!)
        #expect(store.get("missing") == nil)
        store.set("k", "v")
        #expect(store.get("k") == "v")
        let id = store.persistentDeviceId()
        #expect(store.persistentDeviceId() == id)
    }

    @Test func aPropertyWhoseGetterThrowsReadsAsAbsent() {
        let make = JSObject.global.Function.function!.new("""
            const o = {}; Object.defineProperty(o, "localStorage", { get() { throw new Error("SecurityError") } }); return o
            """)
        #expect(jsProperty(make().object!, "localStorage").isUndefined)
    }

    @Test func theHostGlobalsAreRead() {
        defer {
            _ = JSObject.global.Reflect.object!.deleteProperty!(JSObject.global, "__dalUsageContextDisabled")
            _ = JSObject.global.Reflect.object!.deleteProperty!(JSObject.global, "__dalAppVersion")
        }
        JSObject.global.__dalAppVersion = .string("4.5.6")
        #expect(hostProvidedAppVersion() == "4.5.6")
        JSObject.global.__dalUsageContextDisabled = .boolean(true)
        #expect(deviceContextDisabled())
        JSObject.global.__dalUsageContextDisabled = .string("false")
        #expect(!deviceContextDisabled())
        JSObject.global.__dalUsageContextDisabled = .string("1")
        #expect(deviceContextDisabled())
        // A getter, as every other host global may be.
        JSObject.global.__dalUsageContextDisabled = .object(JSClosure { _ in .boolean(true) })
        #expect(deviceContextDisabled())
        // A getter that throws reads as unset instead of unwinding the client.
        let throwing = JSObject.global.Function.function!.new("throw new Error('no request context')")
        JSObject.global.__dalUsageContextDisabled = .object(throwing)
        #expect(!deviceContextDisabled())
        JSObject.global.__dalAppVersion = .object(throwing)
        #expect(hostProvidedAppVersion() == nil)
        // An accessor property whose getter throws, as a request-scoped host may define.
        _ = JSObject.global.Function.function!.new("""
            Object.defineProperty(globalThis, "__dalAppVersion", { configurable: true, get() { throw new Error("no request") } })
            """)()
        #expect(hostProvidedAppVersion() == nil)
        // A finite non-zero number opts out, failing closed; 0 and NaN do not.
        JSObject.global.__dalUsageContextDisabled = .number(1)
        #expect(deviceContextDisabled())
        JSObject.global.__dalUsageContextDisabled = .number(0)
        #expect(!deviceContextDisabled())
        JSObject.global.__dalUsageContextDisabled = .number(.nan)
        #expect(!deviceContextDisabled())
    }

    /// Under Node the wasm core also reads process.env, as tongue-node does.
    @Test func underNodeTheEnvironmentIsRead() throws {
        let env = try #require(JSObject.global.process.object?.env.object)
        let saved = (env.DAL_USAGE_CONTEXT_DISABLED, env.DAL_APP_VERSION)
        defer {
            let reflect = JSObject.global.Reflect.object!
            for (name, value) in [("DAL_USAGE_CONTEXT_DISABLED", saved.0), ("DAL_APP_VERSION", saved.1)] {
                if value.isUndefined { _ = reflect.deleteProperty!(env, name) } else { env[name] = value }
            }
        }
        env.DAL_APP_VERSION = .string("7.8.9")
        #expect(hostProvidedAppVersion() == "7.8.9")
        env.DAL_USAGE_CONTEXT_DISABLED = .string("false")
        #expect(!deviceContextDisabled())
        env.DAL_USAGE_CONTEXT_DISABLED = .string("1")
        #expect(deviceContextDisabled())
    }
    #endif
}
