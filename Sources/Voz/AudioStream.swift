#if canImport(CoreML)
import Foundation

#if canImport(AVFoundation)
// `@preconcurrency` for the same reason AudioIO uses it: the converter callback
// runs synchronously on this thread, so its Sendable warnings do not apply.
@preconcurrency import AVFoundation
#endif

/// A source of mono 16 kHz samples that does not require the whole file at once.
///
/// Transcription reads the file in order and never looks back further than the
/// window it is working on, so holding all of it is only ever a convenience. On
/// a long recording it is an expensive one: an hour of audio is 230 MB of
/// `Float` before the model has allocated anything, and a video editor is
/// working with an hour-long timeline and its own buffers at the same time.
protocol AudioStream {
    /// Total samples, if the source knows. Used only for progress reporting.
    var totalSamples: Int? { get }
    /// Append up to `count` further samples to `into`, returning how many were
    /// added. Zero means the source is exhausted.
    mutating func read(_ count: Int, into: inout [Float]) throws -> Int
}

/// An already-decoded buffer, for callers that hand over samples directly.
struct ArrayAudioStream: AudioStream {
    private let samples: [Float]
    private var position = 0

    init(_ samples: [Float]) { self.samples = samples }

    var totalSamples: Int? { samples.count }

    mutating func read(_ count: Int, into buffer: inout [Float]) throws -> Int {
        let n = Swift.min(count, samples.count - position)
        guard n > 0 else { return 0 }
        buffer.append(contentsOf: samples[position..<(position + n)])
        position += n
        return n
    }
}

#if canImport(AVFoundation)
/// Reads and converts a file incrementally, a few seconds at a time.
struct FileAudioStream: AudioStream {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let chunkFrames: AVAudioFrameCount
    private var finished = false
    private var drained = false

    let totalSamples: Int?

    init(url: URL, sampleRate: Double, chunkSeconds: Double = 10) throws {
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw VozError.invalidAudio("\(url.path): \(error)")
        }
        let inputFormat = file.processingFormat
        guard file.length > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let made = AVAudioConverter(from: inputFormat, to: output)
        else { throw VozError.invalidAudio("\(url.path) decoded to no audio") }
        outputFormat = output
        converter = made
        chunkFrames = AVAudioFrameCount(chunkSeconds * inputFormat.sampleRate)
        totalSamples = Int(Double(file.length) * sampleRate / inputFormat.sampleRate)
    }

    mutating func read(_ count: Int, into buffer: inout [Float]) throws -> Int {
        if finished { return try drain(into: &buffer) }
        let format = file.processingFormat
        // Convert in whole chunks and stop once the request is met. The
        // converter is stateful across calls, which is what keeps a resampled
        // stream continuous instead of clicking at every chunk edge.
        var produced = 0
        while produced < count && !finished {
            guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                throw VozError.invalidAudio("cannot allocate a read buffer")
            }
            // Asking for frames past the end throws rather than returning
            // none, so stop at the end rather than reading into it.
            let remaining = file.length - file.framePosition
            if remaining <= 0 { finished = true; break }
            do {
                try file.read(into: input,
                              frameCount: AVAudioFrameCount(Swift.min(Int64(chunkFrames), remaining)))
            } catch {
                throw VozError.invalidAudio("read failed: \(error)")
            }
            if input.frameLength == 0 { finished = true; break }
            let capacity = AVAudioFrameCount(
                Double(input.frameLength) * (outputFormat.sampleRate / format.sampleRate) + 4096)
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                frameCapacity: capacity) else {
                throw VozError.invalidAudio("cannot allocate a convert buffer")
            }
            // `nonisolated(unsafe)` is sound here because the block runs
            // synchronously on this thread inside `convert`.
            nonisolated(unsafe) var fed = false
            var failure: NSError?
            converter.convert(to: output, error: &failure) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return input
            }
            if let failure { throw VozError.invalidAudio("convert failed: \(failure)") }
            guard let channel = output.floatChannelData?[0] else { break }
            let n = Int(output.frameLength)
            if n > 0 {
                buffer.append(contentsOf: UnsafeBufferPointer(start: channel, count: n))
                produced += n
            }
            if file.framePosition >= file.length { finished = true }
        }
        if finished { produced += try drain(into: &buffer) }
        return produced
    }

    /// Flush whatever the converter is still holding.
    ///
    /// Rate conversion keeps a tail internally, and telling it "no data right
    /// now" between chunks correctly does not release that. Only end-of-stream
    /// does, and without this the last few hundred samples of every file were
    /// silently lost - 40 ms of an eleven-second clip, which is a whole word.
    private mutating func drain(into buffer: inout [Float]) throws -> Int {
        guard !drained else { return 0 }
        drained = true
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                            frameCapacity: 8192) else { return 0 }
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        if let failure { throw VozError.invalidAudio("drain failed: \(failure)") }
        guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { return 0 }
        let n = Int(output.frameLength)
        buffer.append(contentsOf: UnsafeBufferPointer(start: channel, count: n))
        return n
    }
}
#endif
#endif
