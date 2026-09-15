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
/// Both are `async` because the JS host is. On Apple the calls never suspend.
protocol Engine: AnyObject {
    /// Windows decoded per dispatch, read from the model rather than assumed.
    var decodeLanes: Int { get }

    /// Does the decode step reduce its own logits to a token and a duration?
    ///
    /// The Core ML step returns raw logits and the host takes the argmax, which
    /// is free when the result is a shared page. Across a copying boundary the
    /// same choice ships a quarter of a megabyte per call to extract two
    /// integers, so the wasm export reduces in the graph instead.
    var reducesInGraph: Bool { get }

    func runMel(rows: Buffer, melMask: Buffer, mel: Buffer,
                isolation: isolated (any Actor)?) async throws

    func runEncoder(mel: Buffer, keyBias: Buffer, padMask: Buffer, encOut: Buffer,
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
