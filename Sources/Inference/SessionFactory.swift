import ModelStore
import Usage

// The platform seam for building sessions, so model SDKs never name a concrete
// session type (and need no platform conditionals): declare the artifact per
// platform as data, resolve the files, and ask for "this platform's session".

/// This platform's inference session for a model artifact on disk: Core ML on
/// Apple platforms and LiteRT on Android/Linux. wasm uses the JS-hosted factory
/// in `StoredModel.inferenceSession(model:hostGlobal:)` instead.
public func inferenceSession(modelPath: String, sdk: SDKInfo = SDKInfo()) throws -> any InferenceSession {
    #if canImport(CoreML)
    return tracked(try CoreMLSession(modelPath: modelPath), sdk: sdk)
    #elseif canImport(CLiteRt)
    return tracked(try LiteRTSession(modelPath: modelPath), sdk: sdk)
    #else
    throw InferenceError.sessionUnavailable("no on-device inference runtime on this platform")
    #endif
}

/// Build a LiteRT session from in-memory model bytes, for example Android
/// classpath resources.
public func inferenceSession(modelBytes: [UInt8], sdk: SDKInfo = SDKInfo()) throws -> any InferenceSession {
    #if canImport(CLiteRt)
    return tracked(try LiteRTSession(modelPath: "", modelBytes: modelBytes), sdk: sdk)
    #else
    throw InferenceError.sessionUnavailable("in-memory models need LiteRT (Android/Linux)")
    #endif
}

#if os(WASI)
/// A tracked inference session driven by a JS host global (browser/node), for
/// SDKs that create the underlying model session themselves (e.g. a bundled
/// model handed straight to `hostGlobal.createSession`) rather than going
/// through `StoredModel.inferenceSession(model:hostGlobal:)`. The host must
/// expose the `JSInferenceSession` tensor contract on `hostGlobal`. Usage is
/// tracked like every other platform's session.
public func inferenceSession(hostGlobal: String, method: String = "run", sdk: SDKInfo = SDKInfo()) throws -> any InferenceSession {
    tracked(try JSInferenceSession(hostGlobal: hostGlobal, method: method), sdk: sdk)
}
#endif

public extension StoredModel {
    /// Build this platform's inference session for the resolved `model`
    /// artifact (a repo-relative file name). On Apple platforms that is Core
    /// ML; on Android/Linux, LiteRT; on wasm the artifact (node: cached
    /// path; browser: bytes) is handed to `hostGlobal.createSession` and the
    /// host's session is driven through the `JSInferenceSession` tensor
    /// contract. This is the one call a model SDK makes to go from resolved
    /// files to a runnable session.
    func inferenceSession(model: String, hostGlobal: String = "__ModelHost", sdk: SDKInfo = SDKInfo()) async throws -> any InferenceSession {
        #if os(WASI)
        try await createJavaScriptSession(modelFile: model, hostGlobal: hostGlobal)
        return tracked(try JSInferenceSession(hostGlobal: hostGlobal), sdk: sdk)
        #else
        return try Inference.inferenceSession(modelPath: path(model), sdk: sdk)  // already tracked
        #endif
    }
}
