#if canImport(CoreML)
import CoreML
import Accelerate
import Foundation
import PlatformSupport

/// Core ML inference backend (Apple platforms): a compiled `.mlmodelc` behind
/// the shared ``InferenceSession`` API.
///
/// Feeds the model's native I/O precision: when an input/output is `float16`
/// (as fp16-exported graphs declare), it converts against a `Tensor`'s
/// `float32` bytes with vImage rather than per-element `NSNumber` subscripting,
/// which is orders of magnitude faster on large tensors (and lets Core ML run
/// the pure-fp16 graph instead of inserting casts). The MLMultiArrays and the
/// feature provider are built once and reused across `run` calls of the same
/// shape (e.g. a fixed-window model over many chunks). `int32`/`float32` I/O is
/// copied directly; `int64` inputs are rejected (Core ML has no int64 tensors).
final class CoreMLSession: InferenceSession, @unchecked Sendable {
    /// Core ML queues concurrent requests and places them itself, which is how
    /// a two-engine part gets both engines from one session.
    let runsConcurrently = true

    private let model: MLModel
    private let lock = NSLock()
    /// Input arrays and the provider over them, kept so a run allocates
    /// nothing, and pooled so runs do not have to take turns.
    ///
    /// One shared set would mean holding a lock across the prediction itself,
    /// so the session could not overlap its own dispatches, and overlap is how a
    /// two-engine part uses both engines. The lock covers leasing a set, not
    /// running with it.
    private struct Binding {
        let arrays: [String: MLMultiArray]
        let provider: MLDictionaryFeatureProvider
    }
    private var idle: [Binding] = []
    /// Bindings kept when a run gives one back. Beyond this they are dropped:
    /// the inputs of a model in flight are the caller's memory too.
    private static let pooled = 8

    /// Load a compiled model. `computeUnits` is what the model SDK asks for
    /// (Core ML's `MLComputeUnits`); the environment and the simulator can
    /// override it (see ``configuration(for:)``).
    /// - Parameter functionName: which function of a multifunction model to run (one
    ///   `.mlmodelc` can carry several graphs over shared weights). `nil` uses the model's
    ///   default function.
    init(modelPath: String, computeUnits: ComputeUnits = .all,
         functionName: String? = nil) throws {
        let configuration = CoreMLSession.configuration(for: computeUnits)
        if let functionName {
            // watchOS 11.0 belongs here even though this package declares no watchOS platform.
            // `MLModelConfiguration.functionName` is annotated watchOS 11.0+ in the Core ML
            // header, and a platform left out of an `#available` list falls to `*`, which
            // matches every watchOS version, so the guard passes and the line below fails to
            // compile against the watchOS SDK. `ModelPlatform.current` does route watchOS to
            // `.apple`.
            guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, watchOS 11.0, *)
            else {
                throw InferenceError.sessionUnavailable(
                    "multifunction models need iOS 18 / macOS 15; '\(functionName)' is unreachable here")
            }
            configuration.functionName = functionName
        }
        model = try MLModel(contentsOf: URL(fileURLWithPath: modelPath),
                            configuration: configuration)
    }

    /// The configuration to load with, in precedence order:
    ///
    /// 1. `DAL_COREML_COMPUTE_UNITS` (`cpu`, `cpuAndGPU`, `cpuAndNeuralEngine`,
    ///    `all`): how a CI job pins itself to a configuration that is
    ///    reproducible there. A virtualized macOS host (CI runners) has no
    ///    Neural Engine, and `.all` can silently yield useless outputs rather
    ///    than failing.
    /// 2. The simulator, which has no Neural Engine: CPU only.
    /// 3. What the caller asked for (the SDK's own measured best choice).
    static func configuration(for requested: ComputeUnits = .all) -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        switch environmentVariable("DAL_COREML_COMPUTE_UNITS") {
        case "cpu", "cpuOnly": configuration.computeUnits = .cpuOnly
        case "cpuAndGPU": configuration.computeUnits = .cpuAndGPU
        case "cpuAndNeuralEngine": configuration.computeUnits = .cpuAndNeuralEngine
        case "all": configuration.computeUnits = .all
        default:
            #if targetEnvironment(simulator)
            configuration.computeUnits = .cpuOnly
            #else
            configuration.computeUnits = requested.mlComputeUnits
            #endif
        }
        return configuration
    }

    /// Read off the declared constraint. On a multifunction package `modelDescription` reflects
    /// the function this session was configured with, so `select` and `score` report their own
    /// widths from two sessions over the same file.
    func inputWidth(_ name: String) -> Int? {
        guard let shape = model.modelDescription
            .inputDescriptionsByName[name]?.multiArrayConstraint?.shape,
              let last = shape.last?.intValue, last > 0 else { return nil }
        return last
    }

    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        let binding = try lease(inputs)
        defer { release(binding) }
        for (name, tensor) in inputs { write(tensor, into: binding.arrays[name]!) }

        // The async entry point, not the synchronous one. The synchronous call
        // holds its caller's thread for the whole prediction and Core ML does
        // not overlap two of them: on an M3 Ultra, uhm's 12 windows spend 1.45 s
        // in the model through the synchronous call and 0.42 s through this one,
        // four in flight. This is what `runsConcurrently` promises.
        let prediction: MLFeatureProvider
        if !enterConcurrent() {
            prediction = try predictAlone(binding.provider)
        } else {
            do {
                defer { leaveConcurrent() }
                if #available(macOS 14.0, iOS 17.0, tvOS 17.0, visionOS 1.0, *) {
                    prediction = try await model.prediction(from: binding.provider)
                } else {
                    prediction = try predictSynchronously(binding.provider)
                }
            } catch {
                // Some graphs cannot take a second request in flight: the older
                // whole-window uhm export fails it on an M1's Neural Engine
                // (`ANEProgramProcessRequestDirect ... status=0x16`) rather than
                // queueing it. So a failure is retried once, alone, and if that
                // works the session runs alone from then on. The retry is this
                // one prediction inside this one `run`, so a caller (and the
                // usage count around it) sees one call either way. A model that
                // fails alone as well was not a concurrency problem, and the
                // original error is the one worth reporting.
                markSerialized()
                guard let retried = try? predictAlone(binding.provider) else { throw error }
                prediction = retried
            }
        }
        return try outputs.map { name in
            guard let array = prediction.featureValue(for: name)?.multiArrayValue else {
                throw InferenceError.runFailed("the model returned no '\(name)'")
            }
            return readTensor(array)
        }
    }

    /// Whether this session has learned to run one prediction at a time. Sticky:
    /// a graph that refused a concurrent request once will refuse the next, and
    /// paying for the refusal on every call is slower than never overlapping.
    private var refusedConcurrency = false
    /// Predictions on the concurrent path right now. The serialized path waits
    /// for this to reach zero: a request that failed because another was in
    /// flight would fail its retry too if that other one were still running.
    private var inFlight = 0
    /// Held across a prediction only on the serialized path, so it is the queue
    /// the model needs and never taken while predictions are allowed to overlap.
    private let alone = NSLock()

    /// Join the concurrent path, unless this session has learned not to. One
    /// check-and-count under the lock, so nothing can join after the switch.
    private func enterConcurrent() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !refusedConcurrency else { return false }
        inFlight += 1
        return true
    }

    private func leaveConcurrent() {
        lock.lock(); inFlight -= 1; lock.unlock()
    }

    private func markSerialized() {
        lock.lock(); refusedConcurrency = true; lock.unlock()
    }

    private func concurrentInFlight() -> Int {
        lock.lock(); defer { lock.unlock() }
        return inFlight
    }

    /// One prediction with nothing else running on this model. Waits out the
    /// concurrent ones that were already in flight when the session switched,
    /// which is a handful at most (the caller's depth) and only ever once.
    private func predictAlone(_ provider: MLFeatureProvider) throws -> MLFeatureProvider {
        alone.lock(); defer { alone.unlock() }
        while concurrentInFlight() > 0 { usleep(1_000) }
        return try predictSynchronously(provider)
    }

    /// The synchronous prediction: the pre-iOS-17 path, and the serialized one.
    /// It lives in a synchronous function because inside an `async` one the
    /// compiler picks Core ML's `async` overload of the same name.
    private func predictSynchronously(_ provider: MLFeatureProvider) throws -> MLFeatureProvider {
        try model.prediction(from: provider)
    }

    /// A set of input arrays this run owns until it is done with them.
    private func lease(_ inputs: [String: Tensor]) throws -> Binding {
        lock.lock()
        if let index = idle.firstIndex(where: { matches($0, inputs) }) {
            let binding = idle.remove(at: index)
            lock.unlock()
            return binding
        }
        lock.unlock()
        // Built outside the lock: a shape the pool has never seen costs an
        // allocation, and it should not cost every other run its overlap.
        let desc = model.modelDescription.inputDescriptionsByName
        var arrays: [String: MLMultiArray] = [:]
        var features: [String: Any] = [:]
        for (name, tensor) in inputs {
            let dt = try dataType(for: tensor, declared: desc[name]?.multiArrayConstraint?.dataType)
            let array = try MLMultiArray(shape: tensor.shape.map { NSNumber(value: $0) }, dataType: dt)
            arrays[name] = array
            features[name] = array
        }
        return Binding(arrays: arrays, provider: try MLDictionaryFeatureProvider(dictionary: features))
    }

    private func release(_ binding: Binding) {
        lock.lock(); defer { lock.unlock() }
        guard idle.count < Self.pooled else { return }
        idle.append(binding)
    }

    /// Whether a pooled set is the right shape for these inputs.
    private func matches(_ binding: Binding, _ inputs: [String: Tensor]) -> Bool {
        guard binding.arrays.count == inputs.count else { return false }
        for (name, tensor) in inputs {
            guard let array = binding.arrays[name],
                  array.shape.map(\.intValue) == tensor.shape else { return false }
        }
        return true
    }

    private func dataType(for tensor: Tensor, declared: MLMultiArrayDataType?) throws -> MLMultiArrayDataType {
        switch tensor.element {
        case .int64:
            throw InferenceError.invalidTensor("Core ML takes int32, not int64; export the model accordingly")
        case .int32:
            return .int32
        case .float32:
            // Match the model's declared precision so an fp16 graph gets fp16.
            return declared == .float16 ? .float16 : .float32
        }
    }

    private func write(_ tensor: Tensor, into array: MLMultiArray) {
        let count = tensor.count
        tensor.bytes.withUnsafeBytes { raw in
            if array.dataType == .float16 {
                let src = raw.bindMemory(to: Float.self)
                var s = vImage_Buffer(data: .init(mutating: src.baseAddress!), height: 1,
                                      width: vImagePixelCount(count), rowBytes: count * 4)
                var d = vImage_Buffer(data: array.dataPointer, height: 1,
                                      width: vImagePixelCount(count), rowBytes: count * 2)
                vImageConvert_PlanarFtoPlanar16F(&s, &d, 0)
            } else {
                // Copy exactly the source bytes. Only .int32 and .float32 reach
                // here (see dataType(for:)) and both are 4 bytes per element, so
                // this is the same size the destination was allocated for.
                //
                // Not derived from array.dataType: switching on
                // MLMultiArrayDataType means guessing a width for whatever case
                // a future SDK adds, and guessing too wide overruns the array's
                // buffer. Core ML added .int8 (1 byte) exactly that way.
                array.dataPointer.copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
        }
    }

    private func readTensor(_ array: MLMultiArray) -> Tensor {
        let shape = array.shape.map(\.intValue)
        let count = shape.reduce(1, *)
        let contiguous = isContiguous(array)
        if array.dataType == .int32, contiguous {
            let bytes = array.dataPointer.withMemoryRebound(to: UInt8.self, capacity: count * 4) {
                Array(UnsafeBufferPointer(start: $0, count: count * 4))
            }
            return (try? Tensor(element: .int32, shape: shape, bytes: bytes)) ?? Tensor(float32: [], shape: shape)
        }
        var out = [Float](repeating: 0, count: count)
        if array.dataType == .float16, let rows = rowContiguousLayout(array) {
            // ANE commonly pads the innermost row (for example 200 values to
            // a stride of 224). Convert each logical row from the raw buffer;
            // NSNumber subscripting here costs several times the prediction.
            let src = array.dataPointer.assumingMemoryBound(to: UInt16.self)
            out.withUnsafeMutableBufferPointer { dp in
                for row in 0..<rows.count {
                    var s = vImage_Buffer(
                        data: .init(mutating: src + row * rows.stride), height: 1,
                        width: vImagePixelCount(rows.length), rowBytes: rows.length * 2)
                    var d = vImage_Buffer(
                        data: dp.baseAddress! + row * rows.length, height: 1,
                        width: vImagePixelCount(rows.length), rowBytes: rows.length * 4)
                    vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
                }
            }
        } else if array.dataType == .float32, let rows = rowContiguousLayout(array) {
            let src = array.dataPointer.assumingMemoryBound(to: Float.self)
            out.withUnsafeMutableBufferPointer { dp in
                for row in 0..<rows.count {
                    (dp.baseAddress! + row * rows.length)
                        .update(from: src + row * rows.stride, count: rows.length)
                }
            }
        } else {
            // Arbitrary strides or float64: correct, slower path.
            for i in 0..<count { out[i] = array[i].floatValue }
        }
        return Tensor(float32: out, shape: shape)
    }

    private func isContiguous(_ array: MLMultiArray) -> Bool {
        guard let rows = rowContiguousLayout(array) else { return false }
        return rows.stride == rows.length
    }

    /// A dense sequence of fixed-stride innermost rows. Core ML may pad between
    /// rows, but every higher dimension must still be a regular product of the
    /// dimension below it.
    private func rowContiguousLayout(_ array: MLMultiArray)
        -> (count: Int, length: Int, stride: Int)? {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count >= 2, strides.count == shape.count,
              strides.last == 1 else { return nil }
        let rowStride = strides[shape.count - 2]
        guard rowStride >= shape.last! else { return nil }
        if shape.count > 2 {
            for i in 0..<(shape.count - 2) where strides[i] != shape[i + 1] * strides[i + 1] {
                return nil
            }
        }
        return (shape.dropLast().reduce(1, *), shape.last!, rowStride)
    }
}

extension ComputeUnits {
    var mlComputeUnits: MLComputeUnits {
        switch self {
        case .all: return .all
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .cpuOnly: return .cpuOnly
        }
    }
}

#endif
