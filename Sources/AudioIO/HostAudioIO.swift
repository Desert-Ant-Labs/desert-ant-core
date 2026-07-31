#if os(Android)
import CHostBridge
import FFIBuffer

// Android decode backend: the host (MediaExtractor + MediaCodec, installed by
// the runtime's JNI shim) decodes to mono `Float` at the target rate and hands
// back a length-prefixed FFI buffer (u32 sample rate, then an f32 array). Swift
// links no audio codec; it just reads the buffer with FFIReader.

extension AudioIO {
    static func hostDecode(path: String?, bytes: [UInt8]?, sampleRate: Double) throws -> [Float] {
        let ptr: UnsafeMutablePointer<CChar>? = {
            if let path {
                return path.withCString { host_audio_decode($0, nil, 0, sampleRate) }
            } else if let bytes {
                return bytes.withUnsafeBufferPointer {
                    host_audio_decode(nil, $0.baseAddress, Int64(bytes.count), sampleRate)
                }
            }
            return nil
        }()
        guard let ptr else { throw AudioIOError.decodeFailed("host_audio_decode returned null") }
        defer { host_free(ptr) }

        let base = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        let len = Int(base[0]) << 24 | Int(base[1]) << 16 | Int(base[2]) << 8 | Int(base[3])
        let body = [UInt8](UnsafeBufferPointer(start: base + 4, count: len))
        var reader = FFIReader(body)
        _ = reader.u32()                 // sample rate (host already resampled)
        return reader.f32Array()
    }
}
#endif
