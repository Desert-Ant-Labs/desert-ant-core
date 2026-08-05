#if os(Android)
import Android
import DesertAnt

// JNI entry points for ai.desertant.DesertAntNative, written directly in Swift
// (no C shim). One set for the whole SDK: JNI derives its symbol from the Java
// class name, so these are the shared plumbing over the model-agnostic C ABI in
// `CABI.swift`, and the model is a `modelId` argument. Adding a model adds no
// native symbol and no Kotlin class.
//
// The reusable harness (byte marshalling, thread attach, and installing the
// CHostBridge regex/JSON/HTTP callbacks against the host class) is the core's
// HostBridge module. Handles cross as jlong; text and every payload cross as
// UTF-8/byte arrays, results as the FFIBuffer length-prefixed typed buffer.

private func handle(_ ptr: UnsafeMutableRawPointer?) -> jlong { jlong(Int(bitPattern: ptr)) }
private func pointer(_ handle: jlong) -> UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: Int(handle)) }

/// Non-empty bytes, or nil (the JVM side passes null or an empty array for
/// "absent", and both must reach the C ABI as NULL).
private func optionalBytes(_ env: HostEnv, _ array: jbyteArray?) -> [UInt8]? {
    hostCopyBytes(env, array).flatMap { $0.isEmpty ? nil : $0 }
}

/// Run `body` with `bytes` as a NUL-terminated C string, for the ABI's UTF-8
/// arguments (which the JVM hands over without a terminator).
private func withCText<R>(_ bytes: [UInt8]?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    withHostCText(bytes, body)
}

/// Create a model against the store. `modelId` is the catalog id ("emo",
/// "redact", …); `cacheRoot` is the app cache dir; `directory` is an explicit
/// model dir, or null/empty for the managed layout under `cacheRoot`.
@_cdecl("Java_ai_desertant_DesertAntNative_create")
public func DesertAntNative_create(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                   _ modelId: jbyteArray?, _ cacheRoot: jbyteArray?,
                                   _ directory: jbyteArray?) -> jlong {
    installHostBridge(env, cls)  // wires regex/JSON/http callbacks to the host statics
    return withCText(optionalBytes(env, modelId)) { id in
        withCText(optionalBytes(env, cacheRoot)) { root in
            withCText(optionalBytes(env, directory)) { dir in
                handle(dal_create(id, root, dir))
            }
        }
    }
}

@_cdecl("Java_ai_desertant_DesertAntNative_destroy")
public func DesertAntNative_destroy(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ handle: jlong) {
    dal_destroy(pointer(handle))
}

@_cdecl("Java_ai_desertant_DesertAntNative_isDownloaded")
public func DesertAntNative_isDownloaded(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                         _ handle: jlong) -> jint {
    installHostBridge(env, cls)
    return jint(dal_is_downloaded(pointer(handle)))
}

/// Download/verify the model ahead of time. Blocking; call off the main thread.
@_cdecl("Java_ai_desertant_DesertAntNative_download")
public func DesertAntNative_download(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                     _ handle: jlong) -> jint {
    installHostBridge(env, cls)
    return jint(dal_download(pointer(handle)))
}

/// Run the model over `text` (UTF-8 bytes) with the model's own `options`
/// payload, returning the model's own result payload. Android resolves its device
/// through the host bridge and bills each run on its own, so no group/device id
/// crosses here.
@_cdecl("Java_ai_desertant_DesertAntNative_run")
public func DesertAntNative_run(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                _ handle: jlong, _ text: jbyteArray?,
                                _ options: jbyteArray?) -> jbyteArray? {
    installHostBridge(env, cls)
    guard let bytes = hostCopyBytes(env, text) else { return nil }
    let payload = optionalBytes(env, options) ?? []
    let buf = withCText(bytes) { c in
        payload.withUnsafeBufferPointer { p in
            dal_run(pointer(handle), c, p.baseAddress, Int32(p.count), nil, nil)
        }
    }
    return hostTakeBuffer(env, buf)
}

/// Run an audio model (clear) over mono samples. The audio crosses as one
/// FFIBuffer payload - `f32Array samples`, then an `f64` sample rate - so this
/// reuses the byte-array marshalling every other entry point uses instead of
/// adding jfloatArray handling to the harness. Options and result are the
/// model's own payloads, as in `run`.
@_cdecl("Java_ai_desertant_DesertAntNative_runAudio")
public func DesertAntNative_runAudio(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                     _ handle: jlong, _ audio: jbyteArray?,
                                     _ options: jbyteArray?) -> jbyteArray? {
    installHostBridge(env, cls)
    guard let bytes = optionalBytes(env, audio) else { return nil }
    var reader = FFIReader(bytes)
    let samples = reader.f32Array()
    let sampleRate = reader.f64()
    guard !samples.isEmpty, sampleRate > 0 else { return nil }
    let payload = optionalBytes(env, options) ?? []
    let buf = samples.withUnsafeBufferPointer { s in
        payload.withUnsafeBufferPointer { p in
            dal_run_audio(pointer(handle), s.baseAddress, Int32(s.count), sampleRate,
                          p.baseAddress, Int32(p.count), nil, nil)
        }
    }
    return hostTakeBuffer(env, buf)
}
#endif
