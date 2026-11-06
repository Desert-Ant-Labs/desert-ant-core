import DesertAnt

extension Toxic: BoundModel {
    /// Input payload: `string text`.
    ///
    /// Options payload: `u32 count`, then that many `(string label, f64 threshold)` pairs replacing the
    /// model's default threshold for the head named. An empty payload means the SDK defaults.
    ///
    /// Result payload: `u32 count`, then per head, in ``Label/allCases`` order, `string label`, `f64 score`,
    /// `f64 threshold`, `u32 flagged`.
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        var options = options
        let text = input.string()
        var thresholds: [Label: Double] = [:]
        if !options.isEmpty {
            for _ in 0..<options.u32() {
                let name = options.string()
                let threshold = options.f64()
                if let label = Label(rawValue: name) { thresholds[label] = threshold }
            }
        }
        guard let result = try? await analyze(text, options: Options(thresholds: thresholds)) else { return nil }

        var w = FFIWriter()
        w.u32(Label.allCases.count)
        for label in Label.allCases {
            w.string(label.rawValue)
            w.f64(result.score(label))
            w.f64(result.thresholds[label] ?? 0.5)
            w.u32(result.flagged.contains(label) ? 1 : 0)
        }
        return w.bytes
    }
}

/// How the generic bindings construct Toxic.
public enum ToxicBinding: ModelBinding {
    public static let id = ToxicModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Toxic(directory: directory, cacheRoot: cacheRoot)
    }
}
