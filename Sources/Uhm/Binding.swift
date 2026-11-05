import DesertAnt

extension Uhm: BoundModel {
    /// Input payload: `f32Array samples` (mono), then `f64 sampleRate`, then
    /// an appended `u32 wordCount` with `f64 start, f64 end, string text` per
    /// word. No word group means no reconciliation.
    ///
    /// Options payload: `f64 minConfidence` (NaN means the balanced preset),
    /// `f64 minDurationSec` (NaN means the SDK default), `u32 includeTypes`
    /// (0/1), then an appended `f64 minOverlapFraction` (NaN means 0.5) and
    /// `u32 splitContainedWords`. An empty payload means the SDK defaults.
    /// The bias presets themselves are Swift-side numbers, so no preset id
    /// crosses the boundary and adding one breaks no host.
    ///
    /// Result payload: `f64 audioDuration`, then `u32 count`, then per
    /// detection `f64 start`, `f64 end`, `f64 confidence`, and a
    /// length-prefixed UTF-8 type string (empty when no type was assigned);
    /// then, only when words were sent, `u32 count` and `f64 start, f64 end,
    /// string text` per reconciled word. Groups are appended, never reordered.
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        var options = options
        let samples = input.f32Array()
        let sampleRate = input.f64()
        guard !samples.isEmpty, sampleRate > 0 else { return nil }
        var words: [WordRange]? = nil
        if !input.isAtEnd {
            let count = input.u32()
            guard count <= input.remaining / 20 else { return nil }
            words = (0..<count).map { _ in
                let start = input.f64()
                let end = input.f64()
                return WordRange(start: start, end: end, word: input.string())
            }
        }
        var opts = Options.default
        var reconcile = ReconcileOptions()
        if !options.isEmpty {
            let minConfidence = options.f64()
            if !minConfidence.isNaN { opts.minConfidence = minConfidence }
            let minDuration = options.f64()
            if !minDuration.isNaN { opts.minDurationSec = minDuration }
            opts.includeTypes = options.u32() != 0
            if !options.isAtEnd {
                let fraction = options.f64()
                if !fraction.isNaN { reconcile.minOverlapFraction = fraction }
                reconcile.splitContainedWords = options.u32() != 0
            }
        }
        guard let result = try? await analyze(samples: samples,
                                              sampleRate: Int(sampleRate.rounded()),
                                              options: opts) else {
            return nil
        }
        var w = FFIWriter()
        w.f64(result.audioDuration)
        w.u32(result.fillers.count)
        for f in result.fillers {
            w.f64(f.start)
            w.f64(f.end)
            w.f64(f.confidence)
            w.string(f.type?.rawValue ?? "")
        }
        if let words {
            let reconciled = Uhm.reconcileWords(words, fillers: result.fillers, options: reconcile)
            w.u32(reconciled.count)
            for word in reconciled {
                w.f64(word.start)
                w.f64(word.end)
                w.string(word.word)
            }
        }
        return w.bytes
    }
}

/// How the generic bindings construct Uhm.
public enum UhmBinding: ModelBinding {
    public static let id = UhmModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Uhm(directory: directory, cacheRoot: cacheRoot)
    }
}
