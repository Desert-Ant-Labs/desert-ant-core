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
/// The two storage kinds are deliberately behind one type. `Pipeline` is 700
/// lines of windowing, decode bookkeeping and splice logic that has nothing to
/// say about either, and it reads and writes these buffers by pointer on both
/// platforms.
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
    init(_ shape: [Int]) throws {
        count = shape.reduce(1, *)
        self.shape = shape
        ptr = UnsafeMutablePointer<Element>.allocate(capacity: count)
        ptr.initialize(repeating: 0, count: count)
    }

    deinit { ptr.deallocate() }
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
    let rows: Buffer
    let melOut: Buffer
    let keyBias: Buffer
    let padMask: Buffer
    let melMask: Buffer
    let encOut: Buffer
    let embed: Buffer
    let hIn: Buffer
    let cIn: Buffer
    let encStep: Buffer
    let logitsOut: Buffer
    let hOut: Buffer
    let cOut: Buffer

    init(configuration c: Configuration, lanes: Int, batch: Int = 1) throws {
        let hidden = c.predLayers * c.predHidden
        rows = try Buffer([batch, c.hopLength, 1, c.nRows])
        melOut = try Buffer([batch, c.nMels, 1, c.validFrames])
        keyBias = try Buffer([batch, c.encFrames, 1, 1])
        padMask = try Buffer([batch, 1, 1, c.encFrames])
        melMask = try Buffer([batch, 1, 1, c.validFrames])
        encOut = try Buffer([batch, c.jointHidden, 1, c.encFrames])
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
