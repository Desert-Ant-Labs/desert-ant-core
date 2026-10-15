import ModelStore
import Usage

// The platform seam for building sessions, so model SDKs never name a concrete
// session type (and need no platform conditionals): declare the artifact per
// platform as data, resolve the files, and ask for "this platform's session".

/// This platform's inference session for a model artifact on disk: Core ML on
/// Apple platforms and LiteRT on Android/Linux. wasm uses the JS-hosted factory
/// in `StoredModel.inferenceSession(model:)` instead.
///
/// `computeUnits` is a Core ML concern (LiteRT picks its own delegates), and the
/// environment can still override it - see `CoreMLSession.configuration(for:)`.
public func inferenceSession(modelPath: String, computeUnits: ComputeUnits = .all,
                             functionName: String? = nil,
                             sdk: SDKInfo = SDKInfo()) throws -> any InferenceSession {
    #if canImport(CoreML)
    if modelPath.hasSuffix(".aimodel") {
        #if canImport(CoreAI)
        if #available(macOS 27.0, iOS 27.0, tvOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            return licensed(try CoreAISession(modelPath: modelPath, computeUnits: computeUnits), sdk: sdk)
        }
        #endif
        throw InferenceError.sessionUnavailable("Core AI assets need iOS 27 / macOS 27")
    }
    return licensed(try CoreMLSession(modelPath: modelPath, computeUnits: computeUnits,
                                     functionName: functionName), sdk: sdk)
    #elseif canImport(CLiteRt)
    return licensed(try LiteRTSession(modelPath: modelPath), sdk: sdk)
    #else
    throw InferenceError.sessionUnavailable("no on-device inference runtime on this platform")
    #endif
}

/// Build a LiteRT session from in-memory model bytes, for example Android
/// classpath resources.
public func inferenceSession(modelBytes: [UInt8], sdk: SDKInfo = SDKInfo()) throws -> any InferenceSession {
    #if canImport(CLiteRt)
    return licensed(try LiteRTSession(modelPath: "", modelBytes: modelBytes), sdk: sdk)
    #else
    throw InferenceError.sessionUnavailable("in-memory models need LiteRT (Android/Linux)")
    #endif
}

#if os(WASI)
/// An inference session driven by the JS host, for SDKs that had the host
/// compile the model itself (the `modelBaseUrl` path) rather than going through
/// `StoredModel.inferenceSession(model:)`. It is licensed like every other
/// platform's session.
public func inferenceSession(sdk: SDKInfo = SDKInfo()) throws -> any InferenceSession {
    licensed(JSInferenceSession(), sdk: sdk)
}

/// One signature of the model the JS host compiled itself, for a model with one
/// graph per task (the `modelBaseUrl` path of ``StoredModel/inferenceSessions(model:functions:computeUnits:sdk:)``).
public func inferenceSession(signature: String, sdk: SDKInfo = SDKInfo()) -> any InferenceSession {
    licensed(JSInferenceSession(signature: signature), sdk: sdk)
}
#endif

public extension StoredModel {
    /// Build this platform's inference session for the resolved `model`
    /// artifact (a repo-relative file name). On Apple platforms that is Core
    /// ML; on Android/Linux, LiteRT; on wasm the artifact (node: cached path;
    /// browser: bytes) goes to the JS host, whose session is then driven through
    /// the typed contract in `Sources/JSHost/Host.swift`. This is the one call a
    /// model SDK makes to go from resolved files to a runnable session.
    func inferenceSession(model: String, computeUnits: ComputeUnits = .all,
                          functionName: String? = nil,
                          sdk: SDKInfo = SDKInfo()) async throws -> any InferenceSession {
        #if os(WASI)
        try await createJavaScriptSession(modelFile: model)
        return licensed(JSInferenceSession(), sdk: sdk)
        #else
        return try Inference.inferenceSession(modelPath: path(model), computeUnits: computeUnits,
                                              functionName: functionName, sdk: sdk)  // already licensed
        #endif
    }
}

// Every session the factory builds starts its model's license check, which never blocks the session.
func licensed(_ session: any InferenceSession, sdk: SDKInfo) -> any InferenceSession {
    licenseOnLoad(sdk)
    return session
}

public extension StoredModel {
    /// One session per named function of an artifact that carries several graphs
    /// (one per task): Core ML functions on Apple platforms, LiteRT signatures on
    /// Android/Linux/Windows and in the native Node core, LiteRT.js signatures on
    /// wasm. The names are the same on every platform. Where the runtime allows,
    /// the artifact compiles once and its functions share it: one LiteRT model
    /// with a session per signature, one JS-hosted model run by signature.
    func inferenceSessions(model: String, functions: [String], computeUnits: ComputeUnits = .all,
                           sdk: SDKInfo = SDKInfo()) async throws -> [String: any InferenceSession] {
        #if os(WASI)
        try await createJavaScriptSession(modelFile: model)
        return Dictionary(uniqueKeysWithValues: functions.map {
            ($0, licensed(JSInferenceSession(signature: $0), sdk: sdk))
        })
        #elseif canImport(CoreML)
        var sessions: [String: any InferenceSession] = [:]
        for function in functions {
            sessions[function] = try Inference.inferenceSession(
                modelPath: path(model), computeUnits: computeUnits, functionName: function, sdk: sdk)
        }
        return sessions
        #elseif canImport(CLiteRt)
        let compiled = try LiteRTModel(modelPath: path(model))
        var sessions: [String: any InferenceSession] = [:]
        for function in functions {
            guard compiled.signatures.contains(function) else {
                throw InferenceError.sessionUnavailable("\(model) has no signature '\(function)'")
            }
            sessions[function] = licensed(try LiteRTSession(model: compiled, signature: function), sdk: sdk)
        }
        return sessions
        #else
        throw InferenceError.sessionUnavailable("no on-device inference runtime on this platform")
        #endif
    }
}
