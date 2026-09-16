import DesertAnt

extension Align: BoundModel {
    /// Input: samples, sampleRate, wordCount, then text/start/end per word. Options: language. Result: wordCount, then start/end/refined per word.
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input, options = options
        let samples = input.f32Array()
        let sampleRate = input.f64()
        guard !samples.isEmpty, sampleRate > 0 else { return nil }
        let count = input.u32()
        // A word costs at least 20 bytes on the wire, so a larger count is a malformed buffer.
        guard count <= input.remaining / 20 else { return nil }
        var words: [WordTiming] = []
        words.reserveCapacity(count)
        for _ in 0..<count {
            let text = input.string(); let start = input.f64(); let end = input.f64()
            words.append(WordTiming(text: text, start: start, end: end))
        }
        let language = options.isEmpty ? "en" : options.string()
        guard let out = try? await refine(words, audio: samples, sampleRate: sampleRate, languageCode: language) else { return nil }
        var w = FFIWriter()
        w.u32(out.count)
        for word in out { w.f64(word.start); w.f64(word.end); w.u32(word.refined ? 1 : 0) }
        return w.bytes
    }
}

public enum AlignBinding: ModelBinding {
    public static let id = AlignModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Align(directory: directory, cacheRoot: cacheRoot)
    }
}
