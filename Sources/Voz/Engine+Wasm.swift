#if os(WASI)
import Foundation
import JavaScriptKit

/// The wasm engine: the three models live in JavaScript, and tensors cross as
/// raw bytes.
///
/// The host is a plain JS object on `globalThis.__vozHost` with one method:
///
/// ```js
/// run(model, inputs) -> Promise<{ [name]: { data: Uint8Array, dims, type } }>
/// ```
///
/// Not the shared `dalModelHost` contract from `Sources/JSHost`, which carries
/// one compiled session per module: Voz runs three models and would need a
/// session name on every call, and adding one to the shared contract would
/// change the generated `Imports` for every other model's core. A separate
/// object costs nothing and breaks nothing.
///
/// What the shapes cost is the thing to keep in mind here. Core ML is handed
/// pointers; this copies. So the decode step takes an `enc_step` the host has
/// already gathered (16 lanes x 640 x 8 floats, 327 KB) rather than the whole
/// projection buffer, and returns two argmaxes rather than 8198 logits per
/// frame. That is the same division of labour `Pipeline` already had, which is
/// why it ports without changing.
final class WasmEngine: Engine {
    let decodeLanes: Int
    /// Windows encoded per dispatch. One by default: the graph is a fixed size,
    /// so a batch that is not full costs its empty lanes, and the retry path
    /// almost never fills one.
    let encodeBatch: Int
    /// One call at a time. The browser's windows go over inside a call rather
    /// than across several: there is one JavaScript thread to dispatch from,
    /// and the host's runtime is what places the work from there.
    let encodeDepth = 1
    /// Whether this bundle's encoder has the mel folded into it.
    private let fusedFrontend: Bool
    /// The wasm export reduces in the graph: reading logits back would be a
    /// quarter of a megabyte per call to extract two integers.
    let reducesInGraph = true

    private let host: JSObject
    private let configuration: Configuration
    init(configuration: Configuration, lanes: Int, batch: Int, fused: Bool) throws {
        guard let host = JSObject.global.__vozHost.object else {
            throw VozError.invalidModel("no __vozHost on globalThis")
        }
        self.host = host
        self.configuration = configuration
        decodeLanes = lanes
        encodeBatch = batch
        fusedFrontend = fused
    }

    // MARK: - Crossing

    /// A buffer as the host's tensor shape.
    ///
    /// float32 both ways: `Element` is `Float` off Apple precisely so this is a
    /// copy and not a conversion, and the host gets a `Float32Array` it can hand
    /// to the runtime as is.
    private func tensor(_ buffer: Buffer) -> JSValue {
        tensor(buffer, lanes: buffer.shape.first ?? 1)
    }

    /// The same buffer, described as holding only its first `lanes` entries.
    ///
    /// The staging buffers are as wide as the batch, but the tail of a file and
    /// every retry fill fewer lanes than that. With a dynamic batch axis the
    /// graph can be handed the prefix that is live, so a group of one costs one
    /// window rather than a whole batch.
    private func tensor(_ buffer: Buffer, lanes: Int) -> JSValue {
        var shape = buffer.shape
        let full = shape.first ?? 1
        shape[0] = Swift.min(lanes, full)
        let count = buffer.count / Swift.max(full, 1) * shape[0]
        let values = UnsafeBufferPointer(start: buffer.ptr, count: count)
        let object = JSObject.global.Object.function!.new()
        object["data"] = .object(JSTypedArray<Float>(Array(values)).jsObject)
        object["dims"] = shape.jsValue
        object["type"] = .string("float32")
        return .object(object)
    }

    private func run(_ model: String, isolation: isolated (any Actor)?,
                     _ inputs: [String: JSValue]) async throws -> JSObject {
        let feeds = JSObject.global.Object.function!.new()
        for (name, value) in inputs { feeds[name] = value }
        guard let call = host["run"].function else {
            throw VozError.invalidModel("__vozHost has no run()")
        }
        let promise = call(this: host, model, feeds)
        guard let pending = JSPromise(from: promise) else {
            throw VozError.invalidModel("__vozHost.run did not return a promise")
        }
        let result = try await settle(pending, isolation: isolation)
        guard let outputs = result.object else {
            throw VozError.invalidModel("\(model) returned no outputs")
        }
        return outputs
    }

    /// A JS value that has crossed a continuation.
    ///
    /// WebAssembly here is single threaded and every one of these stays on the
    /// one JavaScript thread that made it, so the concurrency checker's concern
    /// - that a non-Sendable value moves between isolation domains - cannot
    /// arise. Saying so explicitly is cheaper than making `JSValue` Sendable.
    private struct Crossing: @unchecked Sendable {
        let value: JSValue
    }

    /// Await a JS promise without sending its value across an isolation domain.
    private func settle(_ promise: JSPromise,
                        isolation: isolated (any Actor)?) async throws -> JSValue {
        let crossing: Crossing = try await withCheckedThrowingContinuation(
            isolation: isolation
        ) { continuation in
            _ = promise.then(
                success: { value in
                    continuation.resume(returning: Crossing(value: value))
                    return .undefined
                },
                failure: { error in
                    continuation.resume(
                        throwing: VozError.invalidModel("the host failed: \(error)"))
                    return .undefined
                })
        }
        return crossing.value
    }

    /// Copy one named output straight into a preallocated buffer.
    private func read(_ outputs: JSObject, _ name: String, into buffer: Buffer) throws {
        guard let tensor = outputs[name].object,
              let array = JSTypedArray<Float>(from: tensor["data"]) else {
            throw VozError.invalidModel("\(name) missing from the host's outputs")
        }
        // A dynamic batch returns only the lanes that were sent, so a short
        // read is expected; a long one means the graph and the buffer disagree.
        guard array.length <= buffer.count else {
            throw VozError.invalidModel(
                "\(name) has \(array.length) values, expected at most \(buffer.count)")
        }
        array.copyMemory(to: UnsafeMutableBufferPointer(start: buffer.ptr, count: array.length))
    }

    private func readInt32(_ outputs: JSObject, _ name: String, into values: inout [Int32]) throws {
        guard let tensor = outputs[name].object,
              let array = JSTypedArray<Int32>(from: tensor["data"]) else {
            throw VozError.invalidModel("\(name) missing from the host's outputs")
        }
        guard array.length == values.count else {
            throw VozError.invalidModel(
                "\(name) has \(array.length) values, expected \(values.count)")
        }
        values.withUnsafeMutableBufferPointer { array.copyMemory(to: $0) }
    }

    // MARK: - Engine

    func encode(slot index: Int, lanes: Int, buffers: PipelineBuffers,
                isolation: isolated (any Actor)?) async throws {
        let slot = buffers.slots[index]
        // An encoder with the mel folded into it is handed the staged rows and
        // the mask that goes with them; asking for the mel first would only be
        // asking it to do half its own work.
        if !fusedFrontend {
            let outputs = try await run("mel", isolation: isolation, [
                "audio_rows": tensor(slot.rows, lanes: lanes),
                "mel_mask": tensor(slot.melMask, lanes: lanes),
            ])
            try read(outputs, "mel", into: slot.melOut)
        }
        let outputs = try await run("encoder", isolation: isolation,
                                    fusedFrontend
                                    ? ["audio_rows": tensor(slot.rows, lanes: lanes),
                                       "mel_mask": tensor(slot.melMask, lanes: lanes),
                                       "key_bias": tensor(slot.keyBias, lanes: lanes)]
                                    : ["mel": tensor(slot.melOut, lanes: lanes),
                                       "key_bias": tensor(slot.keyBias, lanes: lanes),
                                       "pad_mask": tensor(buffers.padMask, lanes: lanes)])
        try read(outputs, "enc_proj", into: slot.encOut)
    }

    func runDecodeStep(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                       logits: Buffer, tok: inout [Int32], dur: inout [Int32],
                       hOut: Buffer, cOut: Buffer,
                       isolation: isolated (any Actor)?) async throws {
        let outputs = try await run("decoder", isolation: isolation, [
            "embed": tensor(embed),
            "h_in": tensor(hIn),
            "c_in": tensor(cIn),
            "enc_step": tensor(encStep),
        ])
        try readInt32(outputs, "tok", into: &tok)
        try readInt32(outputs, "dur", into: &dur)
        try read(outputs, "h_out", into: hOut)
        try read(outputs, "c_out", into: cOut)
    }
}
#endif
