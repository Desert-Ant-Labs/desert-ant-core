// Reusable Android JNI harness for on-device model SDKs. It provides the byte
// marshalling every JNI binding repeats, and installs the CHostBridge callbacks
// so the pure-Swift core (Regex/JSON, which must not link Foundation on Android)
// can delegate to the host's java.util.regex and JSON parser.
//
// A model's own JNI entry points (@_cdecl("Java_...")) stay in the model; they
// call `installHostBridge(env, cls)` once, then use these helpers to move bytes
// across and to hand back the FFIBuffer result. Nothing here is model-specific.
//
// Text crosses as UTF-8 byte arrays (not jstring, to dodge JNI's modified-UTF-8
// pitfalls); results cross as the FFIBuffer length-prefixed typed payload.
//
// JNI calls go through `env.pointee!.pointee.<Fn>(env, ...)`, the function-table
// pointer Android's Swift overlay exposes.

#if os(Android)
import Android
import CHostBridge
import FFIBuffer

/// The JNI environment pointer as Android's Swift overlay exposes it.
public typealias HostEnv = UnsafeMutablePointer<JNIEnv?>

private nonisolated(unsafe) var gVM: UnsafeMutablePointer<JavaVM?>?
private nonisolated(unsafe) var gHostClass: jclass?
private nonisolated(unsafe) var gRegexMatches: jmethodID?
private nonisolated(unsafe) var gJSONParse: jmethodID?

// MARK: byte-array marshalling

/// Copy a `jbyteArray` into a Swift `[UInt8]` (nil array -> nil, empty -> []).
public func hostCopyBytes(_ env: HostEnv, _ array: jbyteArray?) -> [UInt8]? {
    guard let array else { return nil }
    let len = env.pointee!.pointee.GetArrayLength(env, array)
    guard len > 0 else { return [] }
    var out = [UInt8](repeating: 0, count: Int(len))
    out.withUnsafeMutableBytes { raw in
        env.pointee!.pointee.GetByteArrayRegion(env, array, 0, len,
            raw.baseAddress!.assumingMemoryBound(to: jbyte.self))
    }
    return out
}

/// Build a `jbyteArray` from a Swift `[UInt8]`.
public func hostMakeBytes(_ env: HostEnv, _ bytes: [UInt8]) -> jbyteArray? {
    guard let arr = env.pointee!.pointee.NewByteArray(env, jsize(bytes.count)) else { return nil }
    bytes.withUnsafeBytes { raw in
        if let base = raw.baseAddress {
            env.pointee!.pointee.SetByteArrayRegion(env, arr, 0, jsize(bytes.count),
                base.assumingMemoryBound(to: jbyte.self))
        }
    }
    return arr
}

/// Present optional UTF-8 bytes (which never contain NUL for text) as a
/// NUL-terminated C string for the duration of `body`.
public func withHostCText<R>(_ bytes: [UInt8]?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let bytes else { return body(nil) }
    var terminated = bytes
    terminated.append(0)
    return terminated.withUnsafeBytes { body($0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
}

/// Take an FFIBuffer result (a big-endian uint32 length, then the payload) from
/// the core, copy the payload into a `jbyteArray`, and free the C buffer.
public func hostTakeBuffer(_ env: HostEnv, _ buf: UnsafeMutablePointer<CChar>?) -> jbyteArray? {
    guard let buf else { return nil }
    let b = UnsafeRawPointer(buf).assumingMemoryBound(to: UInt8.self)
    let len = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    let arr = env.pointee!.pointee.NewByteArray(env, jsize(len))
    if let arr, len > 0 {
        (b + 4).withMemoryRebound(to: jbyte.self, capacity: len) { p in
            env.pointee!.pointee.SetByteArrayRegion(env, arr, 0, jsize(len), p)
        }
    }
    ffiFree(buf)
    return arr
}

// MARK: host callbacks (Swift core -> Kotlin, via JNI)

// The core's async paths (which bridge to a Swift-concurrency worker) invoke a
// host callback on an unattached thread; a synchronous path invokes it on the
// already-attached JNI thread. Detaching the JNI thread would corrupt it, so
// attach/detach only when GetEnv shows the thread is not already attached.
private func withHostEnv(_ body: (HostEnv) -> UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let vm = gVM else { return nil }
    var raw: UnsafeMutableRawPointer?
    if vm.pointee!.pointee.GetEnv(vm, &raw, JNI_VERSION_1_6) == JNI_OK, let raw {
        return body(raw.assumingMemoryBound(to: JNIEnv?.self))
    }
    var env: HostEnv?
    guard vm.pointee!.pointee.AttachCurrentThread(vm, &env, nil) == 0, let env else { return nil }
    defer { _ = vm.pointee!.pointee.DetachCurrentThread(vm) }
    return body(env)
}

// Turn a returned jbyteArray into a malloc'd, NUL-terminated C buffer (regex
// reads it as a C string; JSON reads its own length prefix, ignoring the NUL).
private func resultBytes(_ env: HostEnv, _ result: jbyteArray?) -> UnsafeMutablePointer<CChar>? {
    if env.pointee!.pointee.ExceptionCheck(env) == JNI_TRUE {
        env.pointee!.pointee.ExceptionClear(env)
        if let result { env.pointee!.pointee.DeleteLocalRef(env, result) }
        return nil
    }
    guard let result else { return nil }
    let len = env.pointee!.pointee.GetArrayLength(env, result)
    let buf = malloc(Int(len) + 1)!.assumingMemoryBound(to: CChar.self)
    if len > 0 {
        buf.withMemoryRebound(to: jbyte.self, capacity: Int(len)) { p in
            env.pointee!.pointee.GetByteArrayRegion(env, result, 0, len, p)
        }
    }
    buf[Int(len)] = 0
    env.pointee!.pointee.DeleteLocalRef(env, result)
    return buf
}

private func hostRegexMatches(_ pattern: UnsafePointer<CChar>?, _ ci: Int32,
                              _ text: UnsafePointer<CChar>?, _ firstOnly: Int32) -> UnsafeMutablePointer<CChar>? {
    withHostEnv { env in
        guard let p = hostMakeBytes(env, Array(String(cString: pattern!).utf8)),
              let t = hostMakeBytes(env, Array(String(cString: text!).utf8)) else { return nil }
        defer { env.pointee!.pointee.DeleteLocalRef(env, p); env.pointee!.pointee.DeleteLocalRef(env, t) }
        let args = [jvalue(l: p), jvalue(z: jboolean(ci != 0 ? 1 : 0)),
                    jvalue(l: t), jvalue(z: jboolean(firstOnly != 0 ? 1 : 0))]
        let result = args.withUnsafeBufferPointer {
            env.pointee!.pointee.CallStaticObjectMethodA(env, gHostClass, gRegexMatches, $0.baseAddress)
        }
        return resultBytes(env, result)
    }
}

private func hostJSONParse(_ json: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    withHostEnv { env in
        guard let j = hostMakeBytes(env, Array(String(cString: json!).utf8)) else { return nil }
        defer { env.pointee!.pointee.DeleteLocalRef(env, j) }
        let args = [jvalue(l: j)]
        let result = args.withUnsafeBufferPointer {
            env.pointee!.pointee.CallStaticObjectMethodA(env, gHostClass, gJSONParse, $0.baseAddress)
        }
        return resultBytes(env, result)
    }
}

// MARK: install

/// Wire the CHostBridge regex/JSON callbacks to the host class's static
/// methods. Call this once from a model's JNI entry points (idempotent). The
/// host class must expose `static byte[] regexMatches(byte[] pattern, boolean
/// caseInsensitive, byte[] text, boolean firstOnly)` and `static byte[]
/// jsonParseTree(byte[] json)` (see the shared HostBridge.kt).
public func installHostBridge(_ env: HostEnv, _ cls: jclass?) {
    if gHostClass != nil { return }
    _ = env.pointee!.pointee.GetJavaVM(env, &gVM)
    if let cls { gHostClass = env.pointee!.pointee.NewGlobalRef(env, cls) }
    gRegexMatches = env.pointee!.pointee.GetStaticMethodID(env, cls, "regexMatches", "([BZ[BZ)[B")
    gJSONParse = env.pointee!.pointee.GetStaticMethodID(env, cls, "jsonParseTree", "([B)[B")
    if env.pointee!.pointee.ExceptionCheck(env) == JNI_TRUE { env.pointee!.pointee.ExceptionClear(env) }
    if gRegexMatches != nil { host_set_regex_matches(hostRegexMatches) }
    if gJSONParse != nil { host_set_json_parse(hostJSONParse) }
}
#endif
