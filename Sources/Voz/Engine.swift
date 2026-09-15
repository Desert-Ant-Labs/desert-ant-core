// The runtime seam between the shared pipeline and the platform's inference
// backend. The pipeline (framing, windowing, the lane-batched TDT decode, the
// retry and splice logic) is the same math everywhere; what differs per
// platform is who owns the tensor buffers and how the three graphs are
// invoked. Core ML (Assets.swift) and LiteRT (LiteRTAssets.swift) each conform.
//
// The seam is buffers plus three run calls rather than a generic
// run(inputs:outputs:) shape, on purpose: the decode loop dispatches hundreds
// of times per minute of audio, and the things that make it fast - the
// pipeline writing straight into preallocated storage and reading results out
// of the same - are exactly what a marshalling API takes away. This is the
// same reason the Apple path never went through `InferenceSession`.

/// A preallocated tensor the pipeline reads and writes in place. The engine
/// owns the storage (an `MLMultiArray` on Apple, a plain allocation for
/// LiteRT); the pipeline sees only the pointer.
struct EngineBuffer<Element> {
    let ptr: UnsafeMutablePointer<Element>
    let count: Int

    func zero() {
        (UnsafeMutableRawPointer(ptr)).initializeMemory(
            as: UInt8.self, repeating: 0, count: count * MemoryLayout<Element>.stride)
    }
}

/// The loaded model as the pipeline sees it: geometry, vocabulary, the shared
/// buffers, and one call per graph. Buffer shapes are fixed by
/// `Configuration` and `decodeLanes`, identically on every backend:
///
/// - mel:     reads `rows` `[1, hop, 1, nRows]` and `melMask`
///            `[1, 1, 1, validFrames]`, writes its mel output (engine-internal).
/// - encoder: reads that mel plus `keyBias` `[1, encFrames, 1, 1]` (and an
///            all-ones pad mask the engine owns), writes `encOut`
///            `[1, jointHidden, 1, encFrames]`.
/// - decode:  reads `embed` `[lanes, predHidden, 1, 1]`, `hIn`/`cIn`
///            `[lanes, layers*hidden, 1, 1]` and `encStep`
///            `[lanes, jointHidden, 1, width]`, writes `logitsOut`
///            `[lanes, vocab+1+durations, 1, width]` and `hOut`/`cOut`.
///
/// `Element` is whatever the graphs declare for I/O: float16 on Core ML (see
/// Buffers.swift for why), float32 on LiteRT. The pipeline's math is element
/// generic and converts through `Float` where it compares values.
///
/// Not `Sendable` and not reentrant, like the pipeline that drives it: every
/// run call mutates the shared buffers. `Voz` serialises access through an
/// actor. One concurrency shape is allowed and relied on where the decode
/// overlaps the encoder (see `Tuning.overlapsDecode`): `runDecodeStep` may run
/// on another thread while `runMel`/`runEncoder` run here, because the three
/// calls touch disjoint buffers and disjoint underlying models.
protocol VozEngine: AnyObject {
    associatedtype Element: BinaryFloatingPoint

    var configuration: Configuration { get }
    var vocabulary: [String] { get }
    /// Windows decoded per dispatch, read from the artifact rather than assumed.
    var decodeLanes: Int { get }

    var rows: EngineBuffer<Element> { get }
    var melMask: EngineBuffer<Element> { get }
    var keyBias: EngineBuffer<Element> { get }
    var encOut: EngineBuffer<Element> { get }
    var embed: EngineBuffer<Element> { get }
    var hIn: EngineBuffer<Element> { get }
    var cIn: EngineBuffer<Element> { get }
    var encStep: EngineBuffer<Element> { get }
    var logitsOut: EngineBuffer<Element> { get }
    var hOut: EngineBuffer<Element> { get }
    var cOut: EngineBuffer<Element> { get }

    func runMel() throws
    func runEncoder() throws
    func runDecodeStep() throws

    /// The prediction network's embedding table, row-major
    /// `[vocab + 1, predHidden]` in the engine's element type.
    func withEmbedding<T>(_ body: (UnsafeBufferPointer<Element>) throws -> T) rethrows -> T
}
