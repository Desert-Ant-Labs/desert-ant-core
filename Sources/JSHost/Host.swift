// The contract between a wasm core and its JavaScript host. Declared with
// BridgeJS, so the build generates both the Swift call glue and the TypeScript
// type the JS host must satisfy (`dist/bridge-js.d.ts`, `Imports`).
//
// The host arrives through `getImports()` at instantiation rather than on a
// global: `globalThis` is shared by every SDK on a page, while imports belong to
// one instantiated module, so there is nothing to collide.
//
// The JS host is late-bound: a module instantiates at import time, but its
// LiteRT.js session only exists once the app calls `load()`. The seam in
// `js/src/litert.js` supplies an object whose methods forward to whatever host is
// installed by then.
#if os(WASI)
import JavaScriptKit

/// A tensor crossing to or from the JS host. Bytes cross raw (host byte order),
/// so the host rebuilds typed arrays over `data.buffer` with no per-element
/// marshalling; `type` is the ``Tensor.Element`` raw value ("float32", "int32",
/// "int64", "uint8").
@JS public struct HostTensor {
    public var data: JSUint8Array
    public var dims: [Int]
    public var type: String

    public init(data: JSUint8Array, dims: [Int], type: String) {
        self.data = data
        self.dims = dims
        self.type = type
    }
}

/// The model host: how a wasm core compiles and runs its model.
///
/// `createSession` is two methods rather than one taking a path-or-bytes union,
/// because a union is not expressible in the bridge: node hands over the cached
/// file path, the browser the model bytes it fetched.
@JSClass public struct DalModelHost {
    /// Compile the model at a cached path (node).
    @JSFunction public func createSessionFromPath(_ path: String) async throws(JSException)

    /// Compile the model from its bytes (browser).
    @JSFunction public func createSessionFromBytes(_ bytes: JSUint8Array) async throws(JSException)

    /// Run the compiled model over named input tensors, returning named outputs.
    @JSFunction public func run(
        _ inputs: [String: HostTensor]
    ) async throws(JSException) -> [String: HostTensor]

    // A model of several graphs. The three methods above hold one compiled
    // model per module, which is every model's shape but schemer's: it runs
    // three files, two of which carry a signature per sequence window. These
    // compile a file into a model of its own, named by a handle, and run any
    // of its signatures. Handle 0 is the model the methods above compiled (or
    // the page compiled itself on the `modelBaseUrl` path), so a self-hosted
    // model's signatures are reachable too.

    /// The handle of a model already compiled under `key`, or 0. Asked first
    /// so the browser does not copy a file's bytes out of wasm to compile a
    /// model it already has.
    @JSFunction public func findModel(_ key: String) throws(JSException) -> Int

    /// Compile the model at a cached path (node) and return its handle (> 0).
    /// The path is its key.
    @JSFunction public func loadModelFromPath(_ path: String) async throws(JSException) -> Int

    /// Compile the model from its bytes (browser) under `key` and return its
    /// handle (> 0).
    @JSFunction public func loadModelFromBytes(
        _ bytes: JSUint8Array, _ key: String
    ) async throws(JSException) -> Int

    /// Run one signature of a compiled model; an empty `signature` runs its
    /// default one.
    @JSFunction public func runModel(
        _ model: Int, _ signature: String, _ inputs: [String: HostTensor]
    ) async throws(JSException) -> [String: HostTensor]
}

/// The host the JS seam supplied at instantiation.
@JSGetter public var dalModelHost: DalModelHost
#endif
