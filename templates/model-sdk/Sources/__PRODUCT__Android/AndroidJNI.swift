#if os(Android)
import Android
import HostBridge

// JNI entry points for ai.desertant.__MODEL__.__PRODUCT__Native, written directly in Swift
// (no C shim). The reusable harness (byte marshalling, thread attach, and
// installing the CHostBridge JSON/HTTP callbacks against the host class) lives
// in desert-ant-core's HostBridge module; this file forwards to the C ABI in
// CABI.swift. Handles cross as jlong.

private func handle(_ ptr: UnsafeMutableRawPointer?) -> jlong { jlong(Int(bitPattern: ptr)) }
private func pointer(_ handle: jlong) -> UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: Int(handle)) }

@_cdecl("Java_ai_desertant___MODEL____PRODUCT__Native_create")
public func __PRODUCT__Native_create(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                             _ cacheRoot: jbyteArray?, _ directory: jbyteArray?) -> jlong {
    installHostBridge(env, cls)  // wires JSON + http callbacks to __PRODUCT__Native's statics
    let root = hostCopyBytes(env, cacheRoot).flatMap { $0.isEmpty ? nil : Array($0) }
    let dir = hostCopyBytes(env, directory).flatMap { $0.isEmpty ? nil : Array($0) }
    return withHostCText(root) { rootPtr in
        withHostCText(dir) { dirPtr in handle(__MODEL___create(rootPtr, dirPtr)) }
    }
}

@_cdecl("Java_ai_desertant___MODEL____PRODUCT__Native_createBundled")
public func __PRODUCT__Native_createBundled(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                    _ metaJson: jbyteArray?, _ model: jbyteArray?) -> jlong {
    installHostBridge(env, cls)
    guard let meta = hostCopyBytes(env, metaJson), let modelBytes = hostCopyBytes(env, model) else { return 0 }
    return withHostCText(Array(meta)) { metaPtr in
        modelBytes.withUnsafeBufferPointer { buf in
            handle(__MODEL___create_bundled(metaPtr, buf.baseAddress, Int32(buf.count)))
        }
    }
}

@_cdecl("Java_ai_desertant___MODEL____PRODUCT__Native_destroy")
public func __PRODUCT__Native_destroy(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ h: jlong) {
    __MODEL___destroy(pointer(h))
}

@_cdecl("Java_ai_desertant___MODEL____PRODUCT__Native_isDownloaded")
public func __PRODUCT__Native_isDownloaded(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ h: jlong) -> jint {
    jint(__MODEL___is_downloaded(pointer(h)))
}

@_cdecl("Java_ai_desertant___MODEL____PRODUCT__Native_download")
public func __PRODUCT__Native_download(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ h: jlong) -> jint {
    jint(__MODEL___download(pointer(h)))
}

@_cdecl("Java_ai_desertant___MODEL____PRODUCT__Native_run")
public func __PRODUCT__Native_run(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                          _ h: jlong, _ input: jbyteArray?, _ minimumConfidence: jdouble) -> jbyteArray? {
    guard let text = hostCopyBytes(env, input) else { return nil }
    return withHostCText(Array(text)) { textPtr in
        hostTakeBuffer(env, __MODEL___run(pointer(h), textPtr, Double(minimumConfidence)))
    }
}
#endif
