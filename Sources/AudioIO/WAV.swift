// A pure-Swift RIFF/WAVE reader and writer. It is the portable audio codec: the
// fallback decoder on platforms with no OS decoder (Linux/server), and the one
// encoder everywhere (16-bit PCM WAV out is the same bytes on every platform).
// Handles PCM (8/16/24/32-bit int) and IEEE float (32/64-bit); other codecs are
// the host decoder's job.

import Foundation

/// Decoded PCM: interleaved `Float` samples in `[-1, 1]`, with the file's own
/// sample rate and channel count (mixdown/resample happen separately).
public struct PCM: Sendable {
    public var samples: [Float]   // interleaved
    public var sampleRate: Double
    public var channels: Int

    public init(samples: [Float], sampleRate: Double, channels: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public enum WAVError: Error, Sendable {
    case notRIFF, truncated, unsupported(String)
}

public enum WAV {
    // MARK: Decode

    /// Parse a WAV/RIFF byte buffer to interleaved float `PCM`.
    public static func decode(_ bytes: [UInt8]) throws -> PCM {
        guard bytes.count >= 12,
              bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,  // "RIFF"
              bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 // "WAVE"
        else { throw WAVError.notRIFF }

        func u16(_ o: Int) -> Int { Int(bytes[o]) | (Int(bytes[o + 1]) << 8) }
        func u32(_ o: Int) -> Int { Int(bytes[o]) | (Int(bytes[o + 1]) << 8) | (Int(bytes[o + 2]) << 16) | (Int(bytes[o + 3]) << 24) }

        var format = 1, channels = 1, sampleRate = 0, bitsPerSample = 16
        var dataStart = -1, dataSize = 0
        var pos = 12
        while pos + 8 <= bytes.count {
            let id = (bytes[pos], bytes[pos + 1], bytes[pos + 2], bytes[pos + 3])
            let size = u32(pos + 4)
            let body = pos + 8
            if id == (0x66, 0x6D, 0x74, 0x20) {          // "fmt "
                guard body + 16 <= bytes.count else { throw WAVError.truncated }
                format = u16(body)
                channels = max(1, u16(body + 2))
                sampleRate = u32(body + 4)
                bitsPerSample = u16(body + 14)
                if format == 0xFFFE, body + 26 <= bytes.count {  // WAVE_FORMAT_EXTENSIBLE
                    format = u16(body + 24)                       // the real sub-format tag
                }
            } else if id == (0x64, 0x61, 0x74, 0x61) {   // "data"
                dataStart = body
                dataSize = min(size, bytes.count - body)
            }
            pos = body + size + (size & 1)               // chunks are word-aligned
        }
        guard dataStart >= 0 else { throw WAVError.truncated }
        guard sampleRate > 0 else { throw WAVError.unsupported("sample rate 0") }

        let samples = try decodeSamples(bytes, at: dataStart, size: dataSize,
                                        format: format, bits: bitsPerSample)
        return PCM(samples: samples, sampleRate: Double(sampleRate), channels: channels)
    }

    private static func decodeSamples(_ b: [UInt8], at start: Int, size: Int,
                                      format: Int, bits: Int) throws -> [Float] {
        let bytesPer = bits / 8
        guard bytesPer > 0 else { throw WAVError.unsupported("0 bits/sample") }
        let count = size / bytesPer
        var out = [Float](repeating: 0, count: count)
        if format == 3 {                                 // IEEE float
            if bits == 32 {
                for i in 0..<count {
                    let o = start + i * 4
                    let u = UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
                    out[i] = Float(bitPattern: u)
                }
            } else if bits == 64 {
                for i in 0..<count {
                    let o = start + i * 8
                    var u: UInt64 = 0
                    for j in 0..<8 { u |= UInt64(b[o + j]) << (8 * j) }
                    out[i] = Float(Double(bitPattern: u))
                }
            } else { throw WAVError.unsupported("float \(bits)-bit") }
            return out
        }
        guard format == 1 else { throw WAVError.unsupported("format tag \(format)") }
        switch bits {
        case 8:   // unsigned
            for i in 0..<count { out[i] = (Float(b[start + i]) - 128) / 128 }
        case 16:
            for i in 0..<count {
                let o = start + i * 2
                let s = Int16(bitPattern: UInt16(b[o]) | (UInt16(b[o + 1]) << 8))
                out[i] = Float(s) / 32768
            }
        case 24:
            for i in 0..<count {
                let o = start + i * 3
                var v = Int(b[o]) | (Int(b[o + 1]) << 8) | (Int(b[o + 2]) << 16)
                if v & 0x800000 != 0 { v |= ~0xFFFFFF }  // sign-extend
                out[i] = Float(v) / 8388608
            }
        case 32:
            for i in 0..<count {
                let o = start + i * 4
                let u = UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
                out[i] = Float(Int32(bitPattern: u)) / 2147483648
            }
        default:
            throw WAVError.unsupported("PCM \(bits)-bit")
        }
        return out
    }

    // MARK: Encode

    /// Encode interleaved `samples` (in `[-1, 1]`) as a 16-bit PCM WAV buffer.
    public static func encode(_ samples: [Float], sampleRate: Int, channels: Int = 1) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(44 + samples.count * 2)
        func u16(_ v: Int) { out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: Int) { for s in 0..<4 { out.append(UInt8((v >> (8 * s)) & 0xFF)) } }
        func tag(_ s: String) { out.append(contentsOf: s.utf8) }

        let dataSize = samples.count * 2
        let byteRate = sampleRate * channels * 2
        tag("RIFF"); u32(36 + dataSize); tag("WAVE")
        tag("fmt "); u32(16); u16(1); u16(channels); u32(sampleRate)
        u32(byteRate); u16(channels * 2); u16(16)
        tag("data"); u32(dataSize)
        for v in samples {
            let clamped = max(-1, min(1, v))
            let s = Int16((clamped * 32767).rounded())
            u16(Int(UInt16(bitPattern: s)))
        }
        return out
    }
}
