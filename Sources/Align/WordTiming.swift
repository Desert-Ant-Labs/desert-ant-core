import Foundation

/// A single recognized word with a start/end time (seconds). Same shape in and out:
/// the refiner returns these with corrected `start`/`end`.
public struct WordTiming: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    /// True when the refiner adjusted this word (false = kept Apple's original as a safe fallback).
    public var refined: Bool

    public init(text: String, start: TimeInterval, end: TimeInterval, refined: Bool = false) {
        self.text = text
        self.start = start
        self.end = end
        self.refined = refined
    }
}

struct RefinerConfig: Decodable {
    let sample_rate: Int
    let n_fft: Int
    let win_length: Int
    let hop_length: Int
    let n_mels: Int
    let log_eps: Float
    let coarse_frames: Int
    let fine_frames: Int
    let hop_seconds: Double
    let byte_context: Int
    let pad_byte: Int
    let n_fft_bins: Int
    let languages: [String: Int]
}
