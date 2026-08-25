// The log-mel frontend, in Swift, shared by every platform.
//
// It lives here rather than in the model artifact for a measured reason: the
// power spectrum is squared magnitudes floored at 1e-10, and 80% of its bins sit
// below float16's smallest normal number. Computed in float16 the features
// measure 27 dB against 200 dB in Float, and end-to-end routing accuracy falls
// from 97.5% to 84.2%. The Neural Engine is a float16 machine, so the frontend
// cannot live there; it is cheap (about a millisecond) and exact here.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(WASILibc)
import WASILibc
#endif
import AudioDSP
import Foundation

/// Turns samples into the tensor the detector consumes.
struct Frontend: Sendable {
    /// Everything the frontend needs that is not a filter coefficient.
    struct Geometry: Sendable {
        let sampleRate: Int
        let nFFT: Int
        let hop: Int
        let mels: Int
        let frames: Int
        /// Floor applied to the mel energies before the logarithm.
        let clampMin: Float
        /// How far below the loudest bin the features are floored, in decades.
        let floorDecades: Float
        let affineAdd: Float
        let affineDivide: Float

        /// Samples in one analysis window.
        var windowSamples: Int { frames * hop }
    }

    let geometry: Geometry
    private let stft: STFT
    /// [mels * bins], row-major: filter `m` occupies `m * bins ..< (m+1) * bins`.
    private let filters: [Float]
    private let bins: Int

    init(geometry: Geometry, filterTable: [UInt8]) throws {
        self.geometry = geometry
        self.stft = STFT(nFFT: geometry.nFFT, hop: geometry.hop,
                         window: Window.hann(geometry.nFFT, periodic: true),
                         center: true)
        let (filters, bins) = try Frontend.parseFilters(filterTable)
        guard bins == stft.bins else {
            throw EarError.invalidModel(
                "mel filterbank has \(bins) bins, the transform produces \(stft.bins)")
        }
        guard filters.count == geometry.mels * bins else {
            throw EarError.invalidModel("mel filterbank is the wrong size")
        }
        self.filters = filters
        self.bins = bins
    }

    /// `[mels * frames]` log-mel, mel-major, ready to reshape to `[1, mels, frames]`.
    ///
    /// Shorter input than one window is padded with silence rather than
    /// rejected: the tail of a recording is short, and that is not an error.
    func features(_ samples: [Float]) -> [Float] {
        var signal = samples
        let want = geometry.windowSamples
        if signal.count > want { signal.removeLast(signal.count - want) }
        if signal.count < want { signal.append(contentsOf: repeatElement(0, count: want - signal.count)) }

        let spectrum = stft.forward(signal)
        let frames = min(geometry.frames, spectrum.frames)

        // Mel energies, then the logarithm. Kept mel-major so the reduction
        // below walks memory in order.
        var log = [Float](repeating: 0, count: geometry.mels * geometry.frames)
        var peak = -Float.greatestFiniteMagnitude
        for mel in 0..<geometry.mels {
            let filter = mel * bins
            for frame in 0..<frames {
                let row = frame * bins
                var energy: Float = 0
                for bin in 0..<bins {
                    let weight = filters[filter + bin]
                    if weight == 0 { continue }
                    let re = spectrum.re[row + bin], im = spectrum.im[row + bin]
                    energy += weight * (re * re + im * im)
                }
                let value = log10f(max(energy, geometry.clampMin))
                log[mel * geometry.frames + frame] = value
                if value > peak { peak = value }
            }
        }

        // The floor is relative to the loudest bin, which is what makes the
        // features insensitive to how the spectrum was scaled on the way here.
        let floor = peak - geometry.floorDecades
        for i in log.indices {
            log[i] = (max(log[i], floor) + geometry.affineAdd) / geometry.affineDivide
        }
        return log
    }

    /// Start offsets of the `count` most speech-like windows.
    ///
    /// A file handed to a transcriber is not speech end to end. It has a jingle
    /// on the front, music under the host, a long silence where someone was
    /// setting up, or thirty seconds of talking inside five minutes of room
    /// tone. Windows chosen by position land on whichever of those happens to
    /// sit at a third and two thirds of the way in.
    ///
    /// Windows are ranked by how much of their loudness varies at syllable
    /// rate. Speech rises and falls three to six times a second and has gaps
    /// between words; music sustains notes and silence does not vary at all.
    /// Measured over five realistic conditions:
    ///
    /// | condition            | by loudness | by modulation |
    /// |----------------------|-------------|---------------|
    /// | music intro          | 69%         | **100%**      |
    /// | intro and outro      | 50%         | **100%**      |
    /// | music bed under speech | 88%       | 81%           |
    /// | 10% speech in silence | 94%        | 94%           |
    /// | 10% speech in room tone | 100%     | 100%          |
    /// | overall              | 80%         | **95%**       |
    ///
    /// Loudness is the intuitive choice and it is the wrong one: an intro is
    /// mixed louder than the voice that follows it, so ranking by energy picks
    /// the jingle. The detector then reads music as English with a margin up to
    /// 0.60 - confident, wrong, and English, which is the worst combination
    /// available. Multiplying the two scores does not help either (82%), because
    /// the loudness term brings the jingle back.
    ///
    /// This needs no voice-activity model, and costs one pass over the file's
    /// amplitude envelope: see ``modulationScores(_:hop:window:step:)``.
    func windowOffsets(_ samples: [Float], count: Int) -> [Int] {
        let want = geometry.windowSamples
        guard samples.count > want else { return [0] }

        // Candidates every third of a window, so a short utterance still lands
        // inside one of them.
        let step = Swift.max(want / 3, 1)
        let scored = Frontend.modulationScores(samples, hop: geometry.hop,
                                               window: want, step: step)
        return scored.sorted { $0.score > $1.score }
            .prefix(Swift.max(count, 1))
            .map(\.offset)
            .sorted()
    }

    /// Per-window syllable-modulation scores for a whole signal.
    ///
    /// The envelope is built once for the file and band-passed once, and the
    /// per-window scores are then read out of running sums. Scoring each window
    /// independently with a transform costs 16 seconds on a ten-minute file -
    /// measured - against about 45 ms for the detection it is choosing windows
    /// for, which is not a trade worth making for any accuracy.
    ///
    /// Two one-pole filters stand in for a band-pass: the difference of a 8 Hz
    /// and a 2 Hz low-pass keeps what varies at syllable rate. It is not a sharp
    /// filter and does not need to be, because the score only ranks windows of
    /// one file against each other.
    static func modulationScores(_ samples: [Float], hop: Int, window: Int,
                                 step: Int) -> [(offset: Int, score: Float)] {
        let frames = samples.count / hop
        guard frames > 8 else { return [(0, 0)] }

        var envelope = [Double](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum = 0.0
            let base = frame * hop
            // Every fourth sample: this ranks windows, and a rank does not need
            // the precision that reading all of them would buy.
            for i in Swift.stride(from: base, to: base + hop, by: 4) {
                let x = Double(samples[i])
                sum += x * x
            }
            envelope[frame] = (sum / Double(hop / 4)).squareRoot()
        }

        let rate = 16000.0 / Double(hop)
        func coefficient(_ hz: Double) -> Double { 1 - Foundation.exp(-2.0 * .pi * hz / rate) }
        let fast = coefficient(8), slow = coefficient(2)

        var lowFast = 0.0, lowSlow = 0.0
        var bandEnergy = [Double](repeating: 0, count: frames + 1)
        var totalEnergy = [Double](repeating: 0, count: frames + 1)
        var loudness = [Double](repeating: 0, count: frames + 1)
        for (i, value) in envelope.enumerated() {
            lowFast += fast * (value - lowFast)
            lowSlow += slow * (value - lowSlow)
            let syllabic = lowFast - lowSlow
            // Running sums, so a window's score is two subtractions.
            bandEnergy[i + 1] = bandEnergy[i] + syllabic * syllabic
            totalEnergy[i + 1] = totalEnergy[i] + (value - lowSlow) * (value - lowSlow)
            loudness[i + 1] = loudness[i] + value * value
        }

        let windowFrames = Swift.max(window / hop, 1)
        var raw: [(offset: Int, ratio: Double, loud: Double)] = []
        for offset in Swift.stride(from: 0, through: Swift.max(samples.count - window, 0),
                                   by: step) {
            let from = Swift.min(offset / hop, frames)
            let to = Swift.min(from + windowFrames, frames)
            guard to > from else { continue }
            let band = bandEnergy[to] - bandEnergy[from]
            let total = totalEnergy[to] - totalEnergy[from]
            raw.append((offset, total > 0 ? band / total : 0,
                        loudness[to] - loudness[from]))
        }
        guard !raw.isEmpty else { return [(0, 0)] }

        // A ratio does not know how loud its input was, so near-silence can
        // score like speech: the fluctuation of a noise floor is still mostly
        // in the band this measures. Windows carrying less than a fiftieth of
        // the loudest window's energy are excluded rather than ranked. On real
        // audio the floor changes nothing (98% either way); it is here so that
        // a file with speech in a tenth of it cannot rank its own silence first.
        let peak = raw.map(\.loud).max() ?? 0
        return raw.map { ($0.offset, $0.loud >= 0.02 * peak ? Float($0.ratio) : 0) }
    }

    private static func parseFilters(_ bytes: [UInt8]) throws -> ([Float], Int) {
        guard bytes.count >= 8 else { throw EarError.invalidModel("mel filterbank is truncated") }
        func u32(_ offset: Int) -> Int {
            Int(UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24)
        }
        let mels = u32(0), bins = u32(4)
        let count = mels * bins
        guard bytes.count == 8 + count * 4 else {
            throw EarError.invalidModel("mel filterbank is truncated")
        }
        var values = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let o = 8 + i * 4
            let raw = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8
                | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
            values[i] = Float(bitPattern: raw)
        }
        return (values, bins)
    }
}
