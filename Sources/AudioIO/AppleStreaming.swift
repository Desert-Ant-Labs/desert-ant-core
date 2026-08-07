#if canImport(AVFoundation)
import AVFoundation
import Foundation

// Chunked file I/O for the Apple platforms, so a long file can be processed
// without ever being resident. `AudioIO.decode`/`write` remain the whole-file
// convenience API; these are what a streaming pipeline drives.

public extension AudioIO {
    /// Reads an audio file as mono `Float` at a fixed sample rate, a chunk at a
    /// time. Single pass: make a new one to read the file again.
    ///
    /// Mirrors what ``AudioIO/decode(path:sampleRate:)`` produces, so a caller
    /// can swap one for the other and get the same samples - just never all at
    /// once. Not thread safe.
    final class StreamingReader {
        private let file: AVAudioFile
        private let target: AVAudioFormat
        private let converter: AVAudioConverter?
        private final class EOFFlag: @unchecked Sendable { var reached = false }
        private let sourceEOF = EOFFlag()
        private var finished = false

        /// Total frames in the source, at the source's own rate. For progress.
        public let totalSourceFrames: AVAudioFramePosition
        public let sourceSampleRate: Double

        /// Frames already read from the source, at the source's own rate.
        public var sourceFramePosition: AVAudioFramePosition { file.framePosition }

        public init(path: String, sampleRate: Double) throws {
            do {
                file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            } catch {
                throw AudioIOError.decodeFailed("open \(path): \(error)")
            }
            let source = file.processingFormat
            totalSourceFrames = file.length
            sourceSampleRate = source.sampleRate
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: sampleRate, channels: 1,
                                             interleaved: false) else {
                throw AudioIOError.decodeFailed("cannot build \(sampleRate) Hz mono format")
            }
            self.target = target
            // Already mono at the target rate in float32? Then read straight
            // through and skip the converter entirely.
            let matches = source.sampleRate == sampleRate
                && source.channelCount == 1
                && source.commonFormat == .pcmFormatFloat32
                && !source.isInterleaved
            if matches {
                converter = nil
            } else {
                guard let c = AVAudioConverter(from: source, to: target) else {
                    throw AudioIOError.decodeFailed("cannot convert \(source) to mono \(sampleRate) Hz")
                }
                converter = c
            }
        }

        /// The next up-to-`maxFrames` samples, or nil once the file is drained.
        public func next(maxFrames: Int) throws -> [Float]? {
            if finished { return nil }
            // AVAudioFile.read throws rather than returning nothing when the
            // position is already at the end, so stop before asking.
            if converter == nil, file.framePosition >= file.length {
                finished = true
                return nil
            }
            return try autoreleasepool { () throws -> [Float]? in
                guard let out = AVAudioPCMBuffer(pcmFormat: target,
                                                 frameCapacity: AVAudioFrameCount(maxFrames)) else {
                    throw AudioIOError.decodeFailed("cannot allocate a \(maxFrames)-frame buffer")
                }
                if let converter {
                    let eof = sourceEOF
                    let file = self.file
                    let sourceFormat = file.processingFormat
                    var error: NSError?
                    let status = converter.convert(to: out, error: &error) { need, inStatus in
                        if eof.reached { inStatus.pointee = .endOfStream; return nil }
                        guard let inBuf = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                                           frameCapacity: need) else {
                            inStatus.pointee = .endOfStream
                            return nil
                        }
                        do {
                            try file.read(into: inBuf, frameCount: need)
                        } catch {
                            eof.reached = true
                            inStatus.pointee = .endOfStream
                            return nil
                        }
                        if inBuf.frameLength == 0 {
                            eof.reached = true
                            inStatus.pointee = .endOfStream
                            return nil
                        }
                        inStatus.pointee = .haveData
                        return inBuf
                    }
                    if let error { throw AudioIOError.decodeFailed("\(error)") }
                    if status == .endOfStream { finished = true }
                } else {
                    let remaining = file.length - file.framePosition
                    let want = AVAudioFrameCount(min(AVAudioFramePosition(maxFrames), max(0, remaining)))
                    if want == 0 {
                        finished = true
                        return nil
                    }
                    do {
                        try file.read(into: out, frameCount: want)
                    } catch {
                        throw AudioIOError.decodeFailed("read: \(error)")
                    }
                    if out.frameLength == 0 { finished = true }
                }

                let n = Int(out.frameLength)
                if n == 0 { return nil }
                guard let channel = out.floatChannelData?[0] else { return nil }
                return Array(UnsafeBufferPointer(start: channel, count: n))
            }
        }
    }

    /// Writes an audio file incrementally, encoding per the destination's
    /// extension the same way ``AudioIO/write(_:sampleRate:channels:to:)`` does.
    /// Call ``finish()`` (or let it deinit) to close the file.
    final class StreamingWriter {
        private var file: AVAudioFile?
        private let source: AVAudioFormat
        private let channels: Int
        private let blockFrames = 1 << 16
        private var buffer: AVAudioPCMBuffer?

        public init(to path: String, sampleRate: Int, channels: Int = 1,
                    format: AudioFileFormat? = nil) throws {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: url)
            self.channels = channels

            let resolved = format
                ?? AudioFileFormat.inferred(fromPathExtension: url.pathExtension)
                ?? .wav
            guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: Double(sampleRate),
                                             channels: AVAudioChannelCount(channels),
                                             interleaved: false) else {
                throw AudioIOError.unsupported("cannot describe \(channels)ch @ \(sampleRate) Hz")
            }
            self.source = source

            func open(_ settings: [String: Any]) throws -> AVAudioFile {
                try AVAudioFile(forWriting: url, settings: settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            do {
                file = try open(resolved.settings(sampleRate: sampleRate, channels: channels))
            } catch {
                guard let fallback = resolved.fallbackSettings(sampleRate: sampleRate, channels: channels) else {
                    throw AudioIOError.unsupported("cannot open \(path) for writing: \(error)")
                }
                do { file = try open(fallback) }
                catch { throw AudioIOError.unsupported("cannot open \(path) for writing: \(error)") }
            }
        }

        /// Append `samples` (interleaved when `channels > 1`).
        public func write(_ samples: ArraySlice<Float>) throws {
            guard let file else { throw AudioIOError.unsupported("writer already finished") }
            let frames = samples.count / max(1, channels)
            var offset = 0
            try samples.withUnsafeBufferPointer { sp in
                guard let base = sp.baseAddress else { return }
                while offset < frames {
                    let n = min(blockFrames, frames - offset)
                    let buf: AVAudioPCMBuffer
                    if let existing = buffer, existing.frameCapacity >= AVAudioFrameCount(n) {
                        buf = existing
                    } else {
                        guard let fresh = AVAudioPCMBuffer(pcmFormat: source,
                                                           frameCapacity: AVAudioFrameCount(blockFrames)) else {
                            throw AudioIOError.unsupported("cannot allocate write buffer")
                        }
                        buffer = fresh
                        buf = fresh
                    }
                    buf.frameLength = AVAudioFrameCount(n)
                    guard let channelData = buf.floatChannelData else {
                        throw AudioIOError.unsupported("write buffer has no float storage")
                    }
                    let src = base + offset * channels
                    if channels == 1 {
                        channelData[0].update(from: src, count: n)
                    } else {
                        for c in 0..<channels {
                            let dst = channelData[c]
                            for i in 0..<n { dst[i] = src[i * channels + c] }
                        }
                    }
                    do { try autoreleasepool { try file.write(from: buf) } }
                    catch { throw AudioIOError.unsupported("write failed: \(error)") }
                    offset += n
                }
            }
        }

        public func write(_ samples: [Float]) throws { try write(samples[...]) }

        /// Closes the file. Further writes throw.
        public func finish() { file = nil; buffer = nil }
    }
}
#endif
