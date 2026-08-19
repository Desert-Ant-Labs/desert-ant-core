#if canImport(CoreML)
import CoreML
import Foundation

/// Element type of every model-facing buffer.
///
/// The models declare float16 I/O. That halves the bytes crossing the boundary,
/// and matters more than it looks: with float32 I/O the Neural Engine declined
/// to reuse its cached specialization and re-specialized the encoder on every
/// load. Compute precision was already float16, so the narrower I/O is lossless.
typealias Element = Float16

/// A reusable float16 `MLMultiArray` with direct pointer access.
///
/// Everything on the hot path is preallocated. Core ML otherwise allocates a
/// fresh `MLMultiArray` per output per call, and the decode loop dispatches
/// hundreds of times per minute of audio, so that allocation is a visible share
/// of the total.
final class Buffer {
    let array: MLMultiArray
    let ptr: UnsafeMutablePointer<Element>
    let count: Int

    init(_ shape: [Int]) throws {
        array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float16)
        ptr = UnsafeMutableRawPointer(array.dataPointer).assumingMemoryBound(to: Element.self)
        count = shape.reduce(1, *)
        ptr.update(repeating: 0, count: count)
    }

    func zero() { ptr.update(repeating: 0, count: count) }
}
#endif
