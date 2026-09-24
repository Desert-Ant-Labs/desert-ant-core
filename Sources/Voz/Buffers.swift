import Foundation

#if canImport(CoreML)
import CoreML

/// Element type of every model-facing buffer.
///
/// The Core ML models declare float16 I/O. That halves the bytes crossing the
/// boundary, and matters more than it looks: with float32 I/O the Neural Engine
/// declined to reuse its cached specialization and re-specialized the encoder on
/// every load. Compute precision was already float16, so the narrower I/O is
/// lossless.
typealias Element = Float16
#else

/// Element type of every model-facing buffer, off Apple platforms.
///
/// float32 rather than float16, because that is what crosses the wasm boundary:
/// `Tensor.Element` carries int32, int64 and float32, and the JS host rebuilds
/// typed arrays over the bytes. The weights inside the model are still float16;
/// only the I/O is wider.
///
/// float16 was measured here and is worse, despite being what the Apple build
/// uses: it removes the Cast nodes at every graph edge, worth ~0.3 s, and costs
/// ~0.56 s, because wasm has no hardware float16 and every Element operation on
/// this side - staging audio, the splice, the timing - converts around itself.
///
/// The ONNX exports on Windows declare float32 edges too, with float16 weights
/// inside, because that is what `torch.onnx.export` writes. Binding float32
/// buffers to them means a dispatch converts nothing; the cost is twice the
/// bytes, which on a discrete-memory path would matter and on an integrated
/// GPU does not.
typealias Element = Float
#endif

/// A reusable model-facing buffer with direct pointer access.
///
/// Everything on the hot path is preallocated. Core ML otherwise allocates a
/// fresh `MLMultiArray` per output per call, and the decode loop dispatches
/// hundreds of times per minute of audio, so that allocation is a visible share
/// of the total. The same is true of the wasm path for a different reason: each
/// call copies its tensors across the JS boundary, and a buffer that is reused
/// keeps that to one copy rather than an allocation as well.
///
/// Both storage kinds sit behind one type so `Pipeline`'s windowing, decode
/// bookkeeping and splice logic reads and writes by pointer on both platforms.
final class Buffer {
    let ptr: UnsafeMutablePointer<Element>
    let count: Int
    let shape: [Int]

    #if canImport(CoreML)
    let array: MLMultiArray

    init(_ shape: [Int]) throws {
        array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float16)
        ptr = UnsafeMutableRawPointer(array.dataPointer).assumingMemoryBound(to: Element.self)
        count = shape.reduce(1, *)
        self.shape = shape
        ptr.update(repeating: 0, count: count)
    }
    #else
    /// Plain owned storage off Apple. The ONNX shim binds a base pointer and a
    /// byte count per tensor, and the wasm path copies through `bytes`, so
    /// neither needs a runtime type to wrap it in.
    init(_ shape: [Int]) throws {
        count = shape.reduce(1, *)
        self.shape = shape
        ptr = UnsafeMutablePointer<Element>.allocate(capacity: max(count, 1))
        ptr.initialize(repeating: 0, count: max(count, 1))
    }

    deinit {
        ptr.deinitialize(count: max(count, 1))
        ptr.deallocate()
    }
    #endif

    func zero() { ptr.update(repeating: 0, count: count) }

    /// The buffer's contents as a tensor for the generic inference seam.
    ///
    /// Only the wasm path needs this; Core ML reads the backing `MLMultiArray`
    /// directly and never copies.
    var bytes: [UInt8] {
        UnsafeRawBufferPointer(start: ptr, count: count * MemoryLayout<Element>.size)
            .withUnsafeBytes { Array($0) }
    }

    /// Fill from a tensor's raw bytes, which is how a model's output arrives
    /// back from the JS host.
    func load(_ raw: [UInt8]) throws {
        let wanted = count * MemoryLayout<Element>.size
        guard raw.count == wanted else {
            throw VozError.invalidModel("expected \(wanted) bytes for \(shape), got \(raw.count)")
        }
        raw.withUnsafeBytes { source in
            UnsafeMutableRawPointer(ptr).copyMemory(from: source.baseAddress!, byteCount: wanted)
        }
    }
}

/// Every buffer the pipeline reuses, allocated once.
///
/// A struct rather than thirteen fields on `Pipeline` because the engine needs
/// the same set: Core ML binds them into its feature providers and output
/// backings at init, and the wasm engine reads and writes them per call.
struct PipelineBuffers {
    /// What one in-flight encode owns: everything the frontend writes and the
    /// encoder reads or fills. Two concurrent dispatches cannot share these -
    /// they are bound into feature providers and output backings - so depth
    /// costs a set each, about 1.1 MB per batch lane for this model.
    ///
    /// A slot is as wide as the batch, because a call may carry several
    /// windows: depth is how many calls are in flight, batch is how many
    /// windows are in one. Core ML takes one window per call and several calls
    /// at once; the browser takes several windows in a single call.
    struct Frontend {
        let rows: Buffer
        let melMask: Buffer
        let keyBias: Buffer
        let melOut: Buffer
        let encOut: Buffer
    }

    let slots: [Frontend]
    /// The attention mask every window shares: it is all ones and read-only, so
    /// one copy serves every slot. Still as wide as the batch, because it is
    /// sent alongside lanes that are, and a graph with a batch axis expects the
    /// two to agree.
    let padMask: Buffer
    let embed: Buffer
    let hIn: Buffer
    let cIn: Buffer
    let encStep: Buffer
    let logitsOut: Buffer
    let hOut: Buffer
    let cOut: Buffer

    init(configuration c: Configuration, lanes: Int, batch: Int = 1, depth: Int = 1) throws {
        let hidden = c.predLayers * c.predHidden
        let batch = max(1, batch)
        slots = try (0..<max(1, depth)).map { _ in
            Frontend(rows: try Buffer([batch, c.hopLength, 1, c.nRows]),
                     melMask: try Buffer([batch, 1, 1, c.validFrames]),
                     keyBias: try Buffer([batch, c.encFrames, 1, 1]),
                     melOut: try Buffer([batch, c.nMels, 1, c.validFrames]),
                     encOut: try Buffer([batch, c.jointHidden, 1, c.encFrames]))
        }
        padMask = try Buffer([batch, 1, 1, c.encFrames])
        embed = try Buffer([lanes, c.predHidden, 1, 1])
        hIn = try Buffer([lanes, hidden, 1, 1])
        cIn = try Buffer([lanes, hidden, 1, 1])
        encStep = try Buffer([lanes, c.jointHidden, 1, c.decodeWidth])
        logitsOut = try Buffer([lanes, c.vocabSize + 1 + c.durations.count, 1, c.decodeWidth])
        hOut = try Buffer([lanes, hidden, 1, 1])
        cOut = try Buffer([lanes, hidden, 1, 1])

        // pad_mask stays all ones on purpose. Zeroing the convolution input over
        // padded frames makes those frames explode through the BatchNorm that
        // follows, until their attention scores overpower the additive mask and
        // silence the whole utterance. Masking attention alone is enough.
        padMask.ptr.update(repeating: 1, count: padMask.count)
    }
}
