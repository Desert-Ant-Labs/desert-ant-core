#if canImport(CoreML)
import Foundation

/// How the three models get run.
///
/// `Pipeline` owns the windowing, the lane-batched decode and the splice, and
/// none of that depends on the runtime underneath: it reads and writes the
/// buffers either way and asks for a model call between them. What a runtime
/// brings is how a call is made, and how much a call costs.
///
/// Core ML is handed the preallocated `MLMultiArray`s directly and writes its
/// results back into ours through `outputBackings`, so a dispatch copies
/// nothing. That is the shape the buffers are built for, and it is why they are
/// allocated once and bound at load rather than passed per call.
///
/// The calls are `async` because a runtime's may be - a pipeline that cannot
/// suspend cannot host one that returns a promise. Core ML's complete
/// synchronously, so nothing here suspends today: see the note on `predict` in
/// `Engine+CoreML.swift`, which is load-bearing.
protocol Engine: AnyObject {
    /// Windows decoded per dispatch, read from the model rather than assumed.
    var decodeLanes: Int { get }

    /// How many encodes may be in flight at once, and so how many slots of
    /// frontend buffers the pipeline keeps.
    ///
    /// Core ML places concurrent requests itself, including across the two
    /// Neural Engines of an Ultra part, so a runtime that overlaps says more
    /// than one here and gets windows handed to it before the last has landed.
    var encodeDepth: Int { get }

    /// One window, from the staged audio rows of `slot` to that slot's encoder
    /// projections. Slots do not share buffers, so calls on different slots may
    /// overlap.
    func encode(slot: Int, buffers: PipelineBuffers,
                isolation: isolated (any Actor)?) async throws

    /// Run one lane-batched decode step, writing `logits` and the new recurrent
    /// state.
    func runDecodeStep(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                       logits: Buffer, hOut: Buffer, cOut: Buffer,
                       isolation: isolated (any Actor)?) async throws
}
#endif
