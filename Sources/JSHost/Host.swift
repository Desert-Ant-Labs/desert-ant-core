// The contract between a wasm core and its JavaScript host, in one place.
//
// Everything the Swift side needs from JS on wasm - compiling the model,
// running it - is declared here with BridgeJS, so the build generates both the
// Swift call glue and the TypeScript type the JS host must satisfy
// (`dist/bridge-js.d.ts`, `Imports`). Before, each seam reached into
// `JSObject.global` by name and unwrapped `JSValue`s by hand, and the contract
// existed only as a doc comment that `js/src/litert.js` was trusted to match.
//
// The host arrives through `getImports()` at instantiation rather than on a
// global. That is what let the per-model host global go away: `globalThis` is
// shared by every SDK on a page, so the name had to be unique per model
// (`__EmoHost`, `__RedactHost`), and it was threaded from the catalog through
// the session factory, the model store, and each model's `ModelLoading.swift`
// into the JS package's `codec.js`. Imports belong to one instantiated module,
// so there is nothing to collide and nothing to name.
//
// The JS host is late-bound on purpose: a module instantiates at import time,
// but its LiteRT.js session only exists once the app calls `load()`. The seam in
// `js/src/litert.js` supplies an object whose methods forward to whatever host is
// installed by then, which is the same indirection the global used to provide.
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
/// because a union is not expressible in the bridge and splitting it is clearer
/// anyway: node hands over the cached file path, the browser hands over the model
/// bytes it fetched.
@JSClass public struct DalModelHost {
    /// Compile the model at a cached path (node).
    @JSFunction public func createSessionFromPath(_ path: String) async throws(JSException)

    /// Compile the model from its bytes (browser).
    @JSFunction public func createSessionFromBytes(_ bytes: JSUint8Array) async throws(JSException)

    /// Run the compiled model over named input tensors, returning named outputs.
    @JSFunction public func run(
        _ inputs: [String: HostTensor]
    ) async throws(JSException) -> [String: HostTensor]
}

/// The host the JS seam supplied at instantiation.
@JSGetter public var dalModelHost: DalModelHost
#endif
