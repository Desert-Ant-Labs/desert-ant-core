// POST transport over PlatformSupport's blocking HTTP client, plus the default
// client assembly.

import PlatformSupport
#if os(WASI)
import JavaScriptKit
#endif

/// The shared ingest endpoint. Every SDK reports to the same place, so it is not
/// part of the public API.
private let ingestEndpoint = "https://platform.desertant.ai/api/v1/ingest"

/// A `send` transport that POSTs the serialized body to `endpoint`.
///
/// The HTTP client is async, so every flush is dispatched fire-and-forget on a
/// detached task. (The `beacon` flag is retained for API parity; there is no
/// separate unload-safe path now that the client is fully async.)
public func makeSend(endpoint: String) -> @Sendable (IngestBody, SendOptions) -> Void {
    { body, opts in
        // Best-effort: a body we cannot serialize is dropped rather than thrown
        // (the transport is fire-and-forget). These types always encode.
        guard let json = try? buildBody(body) else { return }
        let payload = Array(json.utf8)
        #if os(WASI)
        // On the browser, an unload flush must use navigator.sendBeacon (a normal
        // fetch is cancelled as the page goes away). text/plain keeps it a CORS
        // "simple" request (the server parses the body as JSON regardless).
        if opts.beacon, jsSendBeacon(endpoint, payload) { return }
        #endif
        let task = Task.detached {
            _ = try? await httpPOST(endpoint, body: payload, contentType: "application/json")
        }
        // When enabled, let a caller await this otherwise fire-and-forget send.
        if telemetryDebugEnabled() {
            Task { await TelemetryDebug.shared.trackSend(task) }
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
    return sendBeacon(url.jsValue, blob.jsValue).boolean ?? false
}
#endif

/// Build a client wired to the shared endpoint, the system clock, a POST
/// transport, and platform-native storage. Everything is derived and persisted
/// internally: attribution is the app's platform identity (bundle id on Apple,
/// package name on Android, hostname on web — see `defaultAppIdentifier`), sent
/// as `app.id`; the device id + re-emit state live in the platform store.
///
/// - Parameters:
///   - appId: overrides the auto-derived app identity. Falls back to the host
///     override (`globalThis.__dalAppId` on WASI, `DAL_APP_ID` env var natively)
///     and then the platform default. Sent as `app.id`; namespaces persisted state.
///   - key: a publishable API key, if the host has one (usually nil; native
///     attributes by `app.id`, browsers by Origin). Falls back to the host
///     override (`globalThis.__dalApiKey` on WASI, `DAL_API_KEY` env var natively).
///   - deviceId: overrides the device id. Defaults to a host-provided id
///     (`globalThis.__dalDeviceId`, for server-side Node) or the generated,
///     persisted per-install UUID.
///   - storage: overrides the persistence backend (e.g. tests).
public func makeClient(
    appId: String? = nil,
    key: String? = nil,
    deviceId: String? = nil,
    platform: String = defaultPlatform,
    windowMs: Int64 = dayMs,
    callCount: (() -> Int)? = nil,
    context: (() -> [String: String]?)? = nil,
    storage: UsageStorage? = nil
) -> UsageClient {
    let resolvedAppId = appId ?? hostProvidedAppId() ?? defaultAppIdentifier()
    let resolvedKey = key ?? hostProvidedApiKey()
    let namespace = resolvedKey ?? resolvedAppId    // state namespaced per attribution identity
    let store = storage ?? defaultStorage()
    let device = resolveDeviceId(deviceId, store)
    return UsageClient(ClientDeps(
        deviceId: device,
        key: resolvedKey,
        appId: resolvedAppId,
        platform: platform,
        callCount: callCount,
        context: context,
        windowMs: windowMs,
        now: systemNowMs,
        loadState: { store.loadState(namespace, device) },
        saveState: { store.saveState($0, namespace, device) },
        send: makeSend(endpoint: ingestEndpoint)
    ))
}
