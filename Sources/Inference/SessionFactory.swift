import ModelStore

// The platform seam for building sessions, so model SDKs never name a concrete
// session type (and need no platform conditionals): declare the artifact per
// platform as data, resolve the files, and ask for "this platform's session".

/// This platform's inference session for a model artifact on disk: a compiled
/// `.mlmodelc` through Core ML on Apple platforms, a `.onnx` through ONNX
/// Runtime on Android/Linux. wasm has no local file inference; use
/// `StoredModel.inferenceSession(model:hostGlobal:)` instead.
public func inferenceSession(modelPath: String) throws -> any InferenceSession {
    #if canImport(CoreML)
    return try CoreMLSession(modelPath: modelPath)
    #elseif canImport(COnnxRuntime)
    return try ORTSession(modelPath: modelPath)
    #else
    throw InferenceError.sessionUnavailable("no on-device inference runtime on this platform")
    #endif
}

/// This platform's inference session for in-memory model bytes (ONNX Runtime
/// platforms; e.g. Android classpath resources).
public func inferenceSession(modelBytes: [UInt8]) throws -> any InferenceSession {
    #if canImport(COnnxRuntime)
    return try ORTSession(modelPath: "", modelBytes: modelBytes)
    #else
    throw InferenceError.sessionUnavailable("in-memory models need ONNX Runtime (Android/Linux)")
    #endif
}

public extension StoredModel {
    /// Build this platform's inference session for the resolved `model`
    /// artifact (a repo-relative file name). On Apple platforms that is Core
    /// ML; on Android/Linux, ONNX Runtime; on wasm the artifact (node: cached
    /// path; browser: bytes) is handed to `hostGlobal.createSession` and the
    /// host's session is driven through the `JSInferenceSession` tensor
    /// contract. This is the one call a model SDK makes to go from resolved
    /// files to a runnable session.
    func inferenceSession(model: String, hostGlobal: String = "__ModelHost") async throws -> any InferenceSession {
        #if os(WASI)
        try await createJavaScriptSession(modelFile: model, hostGlobal: hostGlobal)
        return try JSInferenceSession(hostGlobal: hostGlobal)
        #else
        return try Inference.inferenceSession(modelPath: path(model))
        #endif
    }
}
