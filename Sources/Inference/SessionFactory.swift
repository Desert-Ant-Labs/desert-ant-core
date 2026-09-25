import ModelStore
import Usage
#if os(WASI)
import JSHost
import JavaScriptKit
#endif

// The platform seam for building sessions, so model SDKs never name a concrete
// session type (and need no platform conditionals): declare the artifact per
// platform as data, resolve the files, and ask for "this platform's session".

/// This platform's inference session for a model artifact on disk: Core ML on
/// Apple platforms and LiteRT on Android/Linux. wasm uses the JS-hosted factory
/// in `StoredModel.inferenceSession(model:)` instead.
///
/// `computeUnits` is a Core ML concern (LiteRT picks its own delegates), and the
/// environment can still override it - see `CoreMLSession.configuration(for:)`.
/// `functionName` picks a Core ML multifunction package's function, or a LiteRT
/// model's signature: the same idea on each backend.
public func inferenceSession(modelPath: String, computeUnits: ComputeUnits = .all,
                             functionName: String? = nil,
                             sdk: SDKInfo = SDKInfo()) throws -> any InferenceSession {
    #if canImport(CoreML)
    if modelPath.hasSuffix(".aimodel") {
        #if canImport(CoreAI)
        if #available(macOS 27.0, iOS 27.0, tvOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            return tracked(try CoreAISession(modelPath: modelPath, computeUnits: computeUnits), sdk: sdk)
        }
        #endif
        throw InferenceError.sessionUnavailable("Core AI assets need iOS 27 / macOS 27")
    }
    return tracked(try CoreMLSession(modelPath: modelPath, computeUnits: computeUnits,
                                     functionName: functionName), sdk: sdk)
    #elseif canImport(CLiteRt)
    // A Core ML function and a LiteRT signature are the same idea, one file
    // with several fixed shapes over one copy of the weights, so the one name
    // selects either.
    return tracked(try LiteRTSession(modelPath: modelPath, signature: functionName), sdk: sdk)
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
/// A tracked inference session driven by the JS host, for SDKs that had the host
/// compile the model itself (the `modelBaseUrl` path) rather than going through
/// `StoredModel.inferenceSession(model:)`. Usage is tracked like every other
/// platform's session.
public func inferenceSession(sdk: SDKInfo = SDKInfo()) throws -> any InferenceSession {
    tracked(JSInferenceSession(), sdk: sdk)
}

/// One signature of the model the JS host compiled on the `modelBaseUrl` path,
/// for a self-hosted model that carries several (see `JSInferenceSession`).
public func inferenceSession(hostModelSignature signature: String,
                             sdk: SDKInfo = SDKInfo()) -> any InferenceSession {
    tracked(JSInferenceSession(model: 0, signature: signature), sdk: sdk)
}

/// A session over one signature of model bytes the JS host compiles under
/// `key`, or reuses if it already has: a self-hosted model's second and third
/// graphs, which arrive as sidecars.
public func inferenceSession(hostModelBytes bytes: [UInt8], key: String, signature: String? = nil,
                             sdk: SDKInfo = SDKInfo()) async throws -> any InferenceSession {
    let handle: Int
    do {
        let known = try dalModelHost.findModel(key)
        handle = known > 0 ? known
            : try await dalModelHost.loadModelFromBytes(JSUint8Array(bytes), key)
    } catch {
        throw InferenceError.sessionUnavailable("the host could not compile the model: \(error)")
    }
    return tracked(JSInferenceSession(model: handle, signature: signature), sdk: sdk)
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
        // Each file is compiled once into a model of its own on the host, and
        // a session is one signature of it, so a model of several graphs (or of
        // several windows over one graph's weights) keeps them side by side.
        let handle = try await loadJavaScriptModel(modelFile: model)
        return tracked(JSInferenceSession(model: handle, signature: functionName), sdk: sdk)
        #else
        return try Inference.inferenceSession(modelPath: path(model), computeUnits: computeUnits,
                                              functionName: functionName, sdk: sdk)  // already tracked
        #endif
    }
}
