// The wasm module's exported surface: one declaration per entry point, for every
// model.
//
// This is the wasm twin of `NativeBindings`' `dal_*` C exports, and the shape
// `js/src/sdk.js` normalizes. Being `@JS` (BridgeJS), building a `<Model>Web`
// product generates the JavaScript glue and the TypeScript types for exactly this
// list (`dist/bridge-js.js`, `dist/bridge-js.d.ts`), rather than the surface being
// written once as Swift plumbing and again as a hand-kept `.d.ts`.
//
// It is model-agnostic for the same reason the C ABI is - options in and results
// out are the model's own `FFIBuffer` payloads - so it is declared once here
// instead of per model, and a wasm module carries exactly one model (one product
// per model), which is what lets these delegate to a single installed host.
//
// Only the three entry points that can genuinely fail throw: building a
// self-hosted model, downloading, and running. They cross as thrown JS errors,
// which for the `async` ones is a rejected promise (`throws(JSException)` is what
// BridgeJS supports and what a JS caller expects). The rest cannot fail, so they
// do not make every JS caller write a `catch` for a state that cannot happen.
#if os(WASI)
import JavaScriptKit

/// What this module's model is, for the JS SDK that wraps it.
///
/// `artifact` and `sidecars` are what a `modelBaseUrl` has to serve: the file the
/// host compiles itself, and the files that cross into wasm. They used to be
/// restated in each npm package's `codec.js` as `MODEL_FILES`, mirroring
/// `Catalog.swift` with nothing checking the two agreed - so renaming an artifact
/// broke the self-hosted path for consumers and nothing caught it.
@JS public struct ModelInfo {
    public var id: String
    public var sdkVersion: String
    public var artifact: String
    public var sidecars: [String]

    // Explicit and public: the generated bridge builds this from a
    // `@_transparent` function, which cannot see an internal memberwise init.
    public init(id: String, sdkVersion: String, artifact: String, sidecars: [String]) {
        self.id = id
        self.sdkVersion = sdkVersion
        self.artifact = artifact
        self.sidecars = sidecars
    }
}

@JS public func modelInfo() throws(JSException) -> ModelInfo {
    let model = try installedHost().declaration
    return ModelInfo(
        id: model.id, sdkVersion: model.sdkVersion,
        artifact: model.artifact, sidecars: model.sidecars)
}

/// Create a model instance, lazily: no download and no model load until
/// `download`/`run`, like the native constructor. `cacheRoot` is the base of the
/// managed nested cache (node `~/.cache`; empty in the browser) and `directory`,
/// when given, is an explicit model directory (adopt the files there, else
/// download into it). Returns the handle every other entry point takes, or 0 if
/// there is no model to create, which the JS seam reports as a creation failure.
@JS public func create(cacheRoot: String?, directory: String?) -> Int {
    installedModelHost?.create(cacheRoot: cacheRoot, directory: directory) ?? 0
}

/// Create a model from files the host fetched and compiled itself (the
/// `modelBaseUrl` path): only the sidecars cross into wasm, keyed by their
/// catalog file names, so the multi-MB artifact never does.
@JS public func createSelfHosted(files: [String: JSUint8Array]) throws(JSException) -> Int {
    try installedHost().createSelfHosted(files: files)
}

/// Whether the model behind `handle` is usable with no network.
@JS public func isDownloaded(handle: Int) -> Bool {
    installedModelHost?.isDownloaded(handle: handle) ?? false
}

/// Fetch, verify, and load ahead of time, so the first `run` is instant and a
/// download or load failure surfaces here. A no-op once available.
/// `onProgress` receives the fraction in [0, 1].
///
/// `onProgress` is not optional because BridgeJS rejects an optional closure
/// parameter; the JS seam passes a no-op when the caller supplied none.
@JS public func download(
    handle: Int, onProgress: @escaping (Double) -> Void
) async throws(JSException) -> Bool {
    try await installedHost().download(handle: handle, onProgress: onProgress)
}

/// Run the model over `text`. The model decodes `options` and encodes the
/// result, so this stays model-agnostic. `group` bills several runs as one usage
/// call (release it with `endCallGroup`); `deviceId` attributes the call to one
/// end-user device.
@JS public func run(
    handle: Int, text: String, options: JSUint8Array?, group: String?, deviceId: String?
) async throws(JSException) -> JSUint8Array {
    try await installedHost().run(
        handle: handle, text: text, options: options, group: group, deviceId: deviceId)
}

/// Release a call group opened by passing `group` to `run`.
@JS public func endCallGroup(id: String?) {
    installedModelHost?.endCallGroup(id: id)
}

/// Release the model behind `handle`. Later calls with it fail.
@JS public func destroy(handle: Int) {
    installedModelHost?.destroy(handle: handle)
}

/// Force any tracked session's usage POST out now and await it, so it lands
/// before the caller continues. Requires `globalThis.__dalHttpDebug`.
@JS public func flushTelemetry() async -> Bool {
    await installedModelHost?.flushTelemetry() ?? false
}
#endif
