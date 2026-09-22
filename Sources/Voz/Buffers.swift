#if canImport(CoreML)
#if canImport(CoreAI)
import CoreAI
#endif
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

/// Which runtime's array type a buffer is made of.
///
/// The pipeline never looks at this: it reads and writes buffers by pointer and
/// has nothing to say about storage. What it decides is whose allocation the
/// engine can bind without copying. Core ML binds `MLMultiArray`s into feature
/// providers and output backings; Core AI binds `NDArray`s into `Inputs` and
/// `outputViews`. Allocating the wrong one costs a memcpy per tensor per
/// dispatch - about 2.1 MB of logits on every decode step, which at hundreds of
/// steps a minute is not a rounding error.
enum BufferStorage: Sendable {
    case coreML
    case coreAI
}

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

    private let mlArray: MLMultiArray?
    #if canImport(CoreAI)
    /// A box, because `NDArray` is a struct and Core AI's `outputViews` take
    /// their arrays `inout`: an output has to live somewhere addressable for
    /// the length of a call.
    @available(macOS 27.0, iOS 27.0, *)
    final class Box: @unchecked Sendable {
        var array: NDArray
        init(_ array: NDArray) { self.array = array }
    }
    private let boxed: AnyObject?

    @available(macOS 27.0, iOS 27.0, *)
    var ndBox: Box {
        guard let box = boxed as? Box else {
            preconditionFailure("buffer was not allocated for Core AI")
        }
        return box
    }
    #endif

    /// The Core ML array. Only `CoreMLEngine` asks, and only a `.coreML` buffer
    /// has one.
    var array: MLMultiArray {
        guard let mlArray else { preconditionFailure("buffer was not allocated for Core ML") }
        return mlArray
    }

    init(_ shape: [Int], storage: BufferStorage = .coreML) throws {
        count = shape.reduce(1, *)
        self.shape = shape
        switch storage {
        case .coreML:
            let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float16)
            mlArray = array
            ptr = UnsafeMutableRawPointer(array.dataPointer)
                .assumingMemoryBound(to: Element.self)
            #if canImport(CoreAI)
            boxed = nil
            #endif
        case .coreAI:
            #if canImport(CoreAI)
            guard #available(macOS 27.0, iOS 27.0, *) else {
                throw VozError.unsupportedPlatform
            }
            let box = Box(NDArray(shape: shape, scalarType: .float16))
            ptr = Buffer.base(of: &box.array)
            boxed = box
            mlArray = nil
            #else
            throw VozError.unsupportedPlatform
            #endif
        }
        ptr.update(repeating: 0, count: count)
    }

    func zero() { ptr.update(repeating: 0, count: count) }

    #if canImport(CoreAI)
    /// The address of an `NDArray`'s own storage, kept past the view that
    /// produced it.
    ///
    /// The allocation belongs to the array, and the array is held by the box
    /// for as long as the buffer lives, so the address stays good. Saying so
    /// here is what lets the pipeline go on writing by pointer - which is all
    /// it knows how to do - while the engine binds that same allocation into a
    /// dispatch instead of copying it.
    @available(macOS 27.0, iOS 27.0, *)
    private static func base(of array: inout NDArray) -> UnsafeMutablePointer<Element> {
        let view = array.mutableView(as: Element.self)
        return view.withUnsafeMutablePointer { pointer, _, _ in pointer }
    }
    #endif
}

/// Every buffer the pipeline reuses, allocated once.
///
/// A struct rather than thirteen fields on `Pipeline` because the engine needs
/// the same set: Core ML binds them into its feature providers and output
/// backings at load, so a dispatch copies nothing.
struct PipelineBuffers {
    /// What one in-flight encode owns: everything the frontend writes and the
    /// encoder reads or fills. Two concurrent dispatches cannot share these -
    /// they are bound into feature providers and output backings - so depth
    /// costs a set each, about 1.1 MB for this model.
    struct Frontend {
        let rows: Buffer
        let melMask: Buffer
        let keyBias: Buffer
        let melOut: Buffer
        let encOut: Buffer
    }

    let slots: [Frontend]
    /// The attention mask every window shares: it is all ones and read-only, so
    /// one copy serves every slot.
    let padMask: Buffer
    let embed: Buffer
    let hIn: Buffer
    let cIn: Buffer
    let encStep: Buffer
    let logitsOut: Buffer
    let hOut: Buffer
    let cOut: Buffer

    init(configuration c: Configuration, lanes: Int, depth: Int = 1,
         storage: BufferStorage = .coreML) throws {
        func make(_ shape: [Int]) throws -> Buffer { try Buffer(shape, storage: storage) }
        let hidden = c.predLayers * c.predHidden
        slots = try (0..<max(1, depth)).map { _ in
            Frontend(rows: try make([1, c.hopLength, 1, c.nRows]),
                     melMask: try make([1, 1, 1, c.validFrames]),
                     keyBias: try make([1, c.encFrames, 1, 1]),
                     melOut: try make([1, c.nMels, 1, c.validFrames]),
                     encOut: try make([1, c.jointHidden, 1, c.encFrames]))
        }
        padMask = try make([1, 1, 1, c.encFrames])
        embed = try make([lanes, c.predHidden, 1, 1])
        hIn = try make([lanes, hidden, 1, 1])
        cIn = try make([lanes, hidden, 1, 1])
        encStep = try make([lanes, c.jointHidden, 1, c.decodeWidth])
        logitsOut = try make([lanes, c.vocabSize + 1 + c.durations.count, 1, c.decodeWidth])
        hOut = try make([lanes, hidden, 1, 1])
        cOut = try make([lanes, hidden, 1, 1])

        // pad_mask stays all ones on purpose. Zeroing the convolution input over
        // padded frames makes those frames explode through the BatchNorm that
        // follows, until their attention scores overpower the additive mask and
        // silence the whole utterance. Masking attention alone is enough.
        padMask.ptr.update(repeating: 1, count: padMask.count)
    }
}
#endif
