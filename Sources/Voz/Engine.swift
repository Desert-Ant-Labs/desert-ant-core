import Foundation

/// How the three models get run, and the only thing that differs between a
/// Neural Engine and a browser.
///
/// `Pipeline` owns the windowing, the lane-batched decode and the splice, and
/// none of that cares which runtime is underneath. What does differ is the cost
/// model at the boundary:
///
/// * Core ML is handed the preallocated `MLMultiArray`s directly and writes its
///   results back into ours through `outputBackings`, so a call copies nothing.
/// * The wasm host copies every tensor across the JavaScript boundary in both
///   directions, so the shapes matter: this is why the decode step takes a
///   gathered `enc_step` and returns two argmaxes rather than taking the whole
///   projection buffer and returning 8198 logits per frame.
///
/// Both are `async` because the JS host is. On Apple the calls never suspend,
/// apart from the encode, which is `async` there so several can be in flight.
protocol Engine: AnyObject {
    /// Windows decoded per dispatch, read from the model rather than assumed.
    var decodeLanes: Int { get }

    /// Windows encoded per dispatch.
    ///
    /// One on Core ML: the Neural Engine is fed a window at a time and the
    /// shipping models are exported that way. More than one in a browser, where
    /// each call costs a dispatch and a readback that batching amortises, and
    /// windows never interact - attention is within a window - so it is exact.
    var encodeBatch: Int { get }

    /// How many encodes may be in flight at once, and so how many slots of
    /// frontend buffers the pipeline keeps.
    ///
    /// The other half of ``encodeBatch``: batch is how many windows one call
    /// carries, depth is how many calls are outstanding. Core ML places
    /// concurrent requests itself, including across the two Neural Engines of
    /// an Ultra part, so it takes one window per call and several calls at
    /// once; the browser is one call at a time and puts its windows inside it.
    var encodeDepth: Int { get }

    /// Does the decode step reduce its own logits to a token and a duration?
    ///
    /// The Core ML step returns raw logits and the host takes the argmax, which
    /// is free when the result is a shared page. Across a copying boundary the
    /// same choice ships a quarter of a megabyte per call to extract two
    /// integers, so the wasm export reduces in the graph instead.
    var reducesInGraph: Bool { get }

    /// One batch of windows, from the staged audio rows of `slot` to that
    /// slot's encoder projections.
    ///
    /// Slots share nothing but the read-only `padMask`, so calls on different
    /// slots may overlap. Whether the frontend is a call of its own or folded
    /// into the encoder is the engine's business: both forms leave the same
    /// values in `encOut`.
    ///
    /// `lanes` is how many of the batch's lanes hold a window. The last group
    /// of a file, and every retry, stage fewer than the batch is wide: a
    /// fixed-shape graph runs the empty lanes anyway, while one with a dynamic
    /// batch axis can be handed just the live prefix. It is a parameter rather
    /// than something set beforehand because two encodes are in flight at
    /// depth, and a count kept on the engine would belong to whichever called
    /// last.
    func encode(slot: Int, lanes: Int, buffers: PipelineBuffers,
                isolation: isolated (any Actor)?) async throws

    /// Run one lane-batched decode step.
    ///
    /// Writes either `logits` (Core ML) or `tok`/`dur` (wasm), per
    /// ``reducesInGraph``, along with the new recurrent state.
    func runDecodeStep(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                       logits: Buffer, tok: inout [Int32], dur: inout [Int32],
                       hOut: Buffer, cOut: Buffer,
                       isolation: isolated (any Actor)?) async throws
}
