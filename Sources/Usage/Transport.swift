// POST transport over PlatformSupport's blocking HTTP client, plus the default
// client assembly.

import PlatformSupport
#if os(WASI)
import JavaScriptKit
#endif

/// The shared ingest endpoint. Every SDK reports to the same place, so it is not
/// part of the public API. A host may override it (tests/diagnostics) via
/// `hostProvidedIngestEndpoint()`.
private let defaultIngestEndpoint = "https://events.desertant.com/api/v1/ingest"
private var ingestEndpoint: String { hostProvidedIngestEndpoint() ?? defaultIngestEndpoint }

private let sendTimeoutSeconds = 5.0

/// Whether the key can ride an `Authorization` header on every path this
/// transport uses.
///
/// False on Android, whose host bridge takes a body and a content type only, and
/// on wasm, where a browser's unload flush is a `sendBeacon` and cannot carry a
/// header; one wasm binary is the same code for a page and for a Node process, so
/// it keeps one answer for both rather than branching on the host. Those two keep
/// the key in the body.
private var keyRidesInHeader: Bool {
    if !httpSupportsRequestHeaders { return false }
    #if os(WASI)
    return false
    #else
    return true
    #endif
}

/// A `send` transport that POSTs the serialized body to `endpoint`.
///
/// The HTTP client is async, so every flush is dispatched fire-and-forget on a
/// detached task. `beacon` only changes the path on wasm, where it uses
/// `navigator.sendBeacon`.
///
/// Sends nothing while `usageDisabled()` is on, read per send: the last guard
/// behind the client's own (`ClientDeps.disabled`), for a host that pairs this
/// transport with a client of its own.
public func makeSend(endpoint: String, bearerKey: String? = nil) -> @Sendable (IngestBody, SendOptions) -> Void {
    makeSend(endpoint: endpoint, bearerKey: bearerKey, registry: .shared)
}

/// `registry` is a seam for tests: a send must be in it by the time the
/// returned closure returns, which only a private registry lets a test observe.
/// `disabled` is one too, since the suites run with the switch on.
func makeSend(
    endpoint: String,
    bearerKey: String? = nil,
    registry: InflightSends,
    disabled: @escaping @Sendable () -> Bool = usageDisabled
) -> @Sendable (IngestBody, SendOptions) -> Void {
    { body, opts in
        if disabled() { return }
        // Best-effort: a body we cannot serialize is dropped rather than thrown
        // (the transport is fire-and-forget). These types always encode.
        guard let json = try? buildBody(body) else { return }
        let payload = Array(json.utf8)
        let debug = telemetryDebugEnabled()
        var headers: [String: String] = [:]
        if let bearerKey, keyRidesInHeader { headers["Authorization"] = "Bearer \(bearerKey)" }
        if debug { print("[usage] POST \(endpoint)\n[usage] body: \(json)") }
        #if os(WASI)
        // On the browser, an unload flush must use navigator.sendBeacon (a normal
        // fetch is cancelled as the page goes away). text/plain keeps it a CORS
        // "simple" request (the server parses the body as JSON regardless).
        if opts.beacon, jsSendBeacon(endpoint, payload) { return }
        #endif
        // Registered before this returns, so a caller's `flushTelemetry()` awaits it.
        dispatchTrackedSend(into: registry) { [headers] in
            do {
                // Bounded like the Node and Kotlin ports' sends: `flushTelemetry()`
                // awaits this, and a blackholed endpoint would otherwise hold the
                // caller for URLSession's 60 s default.
                let response = try await httpPOST(
                    endpoint, body: payload, contentType: "application/json", headers: headers,
                    timeout: sendTimeoutSeconds
                )
                if debug {
                    let text = String(decoding: response.body, as: UTF8.self)
                    print("[usage] response: \(response.status) \(text)")
                }
            } catch {
                if debug { print("[usage] send failed: \(error)") }
            }
        }
    }
}

#if os(WASI)
/// `navigator.sendBeacon(endpoint, Blob([payload], {type: text/plain}))`.
private func jsSendBeacon(_ url: String, _ payload: [UInt8]) -> Bool {
    guard let navigator = JSObject.global.navigator.object,
          let sendBeacon = navigator.sendBeacon.function,
          let blobType = JSObject.global.Blob.function else { return false }
    let parts = JSObject.global.Array.function!.new()
    _ = parts.push!(JSTypedArray<UInt8>(payload).jsValue)
    let options = JSObject.global.Object.function!.new()
    options.type = "text/plain;charset=UTF-8".jsValue
    let blob = blobType.new(parts.jsValue, options.jsValue)
    // `this: navigator` is required: sendBeacon is a Navigator method and throws
    // "Illegal invocation" when called detached.
    return sendBeacon(this: navigator, url.jsValue, blob.jsValue).boolean ?? false
}
#endif

/// Build a client wired to the shared endpoint, the system clock, a POST
/// transport, and platform-native storage. Everything is derived and persisted
/// internally: attribution is the app's platform identity (bundle id on Apple,
/// package name on Android, hostname on web; see `defaultAppIdentifier`), sent
/// as `app.id`; the device id + re-emit state live in the platform store.
///
/// - Parameters:
///   - appId: overrides the auto-derived app identity. Falls back to the host
///     override (`globalThis.__dalAppId` on WASI, `DAL_APP_ID` env var natively)
///     and then the platform default. Sent as `app.id`; namespaces persisted state.
///   - key: a publishable API key, if the host has one (usually nil; native
///     attributes by `app.id`, browsers by Origin). Falls back to the host
///     override (`globalThis.__dalApiKey` on WASI, `DAL_API_KEY` env var natively).
///     Sent as `Authorization: Bearer` where the transport sets headers, and in
///     the body where it cannot (`keyRidesInHeader`).
///   - deviceId: overrides the device id. Defaults to a host-provided id
///     (`globalThis.__dalDeviceId`, for server-side Node) or the generated,
///     persisted per-install UUID.
///   - storage: overrides the persistence backend (e.g. tests).
///   - context: overrides the per-event `context` provider. Defaults to the
///     cached host facts (`DeviceContext`), cut to the server set when `platform`
///     is "server" or the device id was supplied rather than generated here.
///     Whatever it returns is sanitized before it is sent (`sanitizeContext`),
///     and ignored while the context opt-out is on (`DesertAnt.sendsDeviceContext`,
///     `DAL_USAGE_CONTEXT_DISABLED`).
///   - send: overrides the transport. Defaults to the real POST; a caller-supplied
///     one wins (tests), which is how a test reads the platform tag and the key's
///     placement that this function decides.
///   - disabled: the usage opt-out the client reads before every step. Defaults
///     to `usageDisabled`; a test passes its own, since the suites run with the
///     switch on.
public func makeClient(
    appId: String? = nil,
    key: String? = nil,
    sdk: SDKInfo = SDKInfo(),
    deviceId: String? = nil,
    platform: String = defaultPlatform,
    windowMs: Int64 = dayMs,
    emitIntervalMs: Int64? = nil,
    callCount: (() -> Int)? = nil,
    context: (() -> [String: String]?)? = nil,
    storage: UsageStorage? = nil,
    send: ((IngestBody, SendOptions) -> Void)? = nil,
    disabled: @escaping () -> Bool = usageDisabled
) -> UsageClient {
    let resolvedAppId = appId ?? hostProvidedAppId() ?? defaultAppIdentifier()
    let resolvedKey = trimmedKey(key) ?? hostProvidedApiKey()
    let namespace = resolvedKey ?? resolvedAppId    // state namespaced per attribution identity
    let store = storage ?? defaultStorage()
    let device = resolveDeviceId(deviceId, store)
    // An id from the caller (a tenant's) or the host is not this machine's to
    // describe. Inference passes the persisted id explicitly on its default path,
    // which is why an explicit id equal to it still counts as generated.
    let suppliedId = deviceId ?? hostProvidedDeviceId()
    let deviceIdSupplied = suppliedId != nil && suppliedId != store.get(deviceIdKey)
    // Coalesce a continuously-running server's delta loads to hourly by default.
    let resolvedEmitInterval = emitIntervalMs ?? (platform == "server" ? hourMs : 0)
    return UsageClient(ClientDeps(
        deviceId: device,
        key: resolvedKey,
        keyInBody: !keyRidesInHeader,
        appId: resolvedAppId,
        sdk: sdk,
        platform: platform,
        callCount: callCount,
        context: context ?? defaultContextProvider(platform: platform, deviceIdSupplied: deviceIdSupplied),
        windowMs: windowMs,
        emitIntervalMs: resolvedEmitInterval,
        now: systemNowMs,
        loadState: { store.loadState(namespace, device) },
        saveState: { store.saveState($0, namespace, device) },
        // The key is only known here, so the real transport is built here too; a
        // caller-supplied one still wins (tests).
        send: send ?? makeSend(endpoint: ingestEndpoint, bearerKey: resolvedKey),
        disabled: disabled
    ))
}
