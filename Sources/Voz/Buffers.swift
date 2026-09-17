#if canImport(CoreML)
import CoreML
import Foundation

/// Element type of every model-facing buffer.
///
/// The Core ML models declare float16 I/O. That halves the bytes crossing the
/// boundary, and matters more than it looks: with float32 I/O the Neural Engine
/// declined to reuse its cached specialization and re-specialized the encoder on
/// every load. Compute precision was already float16, so the narrower I/O is
/// lossless.
typealias Element = Float16

/// A reusable model-facing buffer with direct pointer access.
///
/// Everything on the hot path is preallocated. Core ML otherwise allocates a
/// fresh `MLMultiArray` per output per call, and the decode loop dispatches
/// hundreds of times per minute of audio, so that allocation is a visible share
/// of the total.
///
/// A type rather than a bare `MLMultiArray` because `Pipeline` is 700 lines of
/// windowing, decode bookkeeping and splice logic that has nothing to say about
/// storage: it reads and writes these by pointer.
final class Buffer {
    let ptr: UnsafeMutablePointer<Element>
    let count: Int
    let shape: [Int]

    let array: MLMultiArray

    init(_ shape: [Int]) throws {
        array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float16)
        ptr = UnsafeMutableRawPointer(array.dataPointer).assumingMemoryBound(to: Element.self)
        count = shape.reduce(1, *)
        self.shape = shape
        ptr.update(repeating: 0, count: count)
    }

    func zero() { ptr.update(repeating: 0, count: count) }

}

/// Every buffer the pipeline reuses, allocated once.
///
/// A struct rather than thirteen fields on `Pipeline` because the engine needs
/// the same set: Core ML binds them into its feature providers and output
/// backings at load, so a dispatch copies nothing.
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

    init(configuration c: Configuration, lanes: Int) throws {
        let hidden = c.predLayers * c.predHidden
        rows = try Buffer([1, c.hopLength, 1, c.nRows])
        melOut = try Buffer([1, c.nMels, 1, c.validFrames])
        keyBias = try Buffer([1, c.encFrames, 1, 1])
        padMask = try Buffer([1, 1, 1, c.encFrames])
        melMask = try Buffer([1, 1, 1, c.validFrames])
        encOut = try Buffer([1, c.jointHidden, 1, c.encFrames])
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
#endif
