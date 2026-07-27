#if !os(WASI)
@_spi(__PRODUCT__Bindings) import __PRODUCT__
import FFIBuffer
import PlatformSupport

// C ABI over the __PRODUCT__ core, called by the Swift JNI entry points in
// `AndroidJNI.swift` (and usable from any other host language). Kept
// Foundation-free so the Android build ships without the ~50 MB Foundation/ICU
// stack. Instance-based, mirroring the Swift SDK (one `__PRODUCT__` per handle).
//
//   __MODEL___create(cacheRootUTF8, dirUTF8|NULL)              -> handle | NULL
//   __MODEL___create_bundled(metaUTF8, model, modelLen)        -> handle | NULL
//   __MODEL___is_downloaded(handle)                            -> 0/1
//   __MODEL___download(handle)                                 -> 0/-1  (blocks)
//   __MODEL___run(handle, inputUTF8, minimumConfidence)        -> buffer | NULL
//   __MODEL___destroy(handle)
//   __MODEL___string_free(ptr)
//
// Results come back as a self-describing binary buffer (no hand-rolled JSON):
// a big-endian uint32 payload length, then the payload. The async core API is
// bridged synchronously (host worker threads).

private final class Handle { let core: __PRODUCT__; init(_ core: __PRODUCT__) { self.core = core } }

private func core(_ handle: UnsafeMutableRawPointer?) -> __PRODUCT__? {
    guard let handle else { return nil }
    return Unmanaged<Handle>.fromOpaque(handle).takeUnretainedValue().core
}

@_cdecl("__MODEL___create")
public func __MODEL___create(
    _ cacheRoot: UnsafePointer<CChar>?, _ directory: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    let instance = __PRODUCT__(
        directory: directory.map { String(cString: $0) },
        cacheRoot: cacheRoot.map { String(cString: $0) })
    return Unmanaged.passRetained(Handle(instance)).toOpaque()
}

@_cdecl("__MODEL___create_bundled")
public func __MODEL___create_bundled(
    _ meta: UnsafePointer<CChar>?, _ model: UnsafePointer<UInt8>?, _ modelLen: Int32
) -> UnsafeMutableRawPointer? {
    guard let meta, let model else { return nil }
    let bytes = Array(UnsafeBufferPointer(start: model, count: Int(modelLen)))
    guard let assets = try? ModelAssets(metaJSON: String(cString: meta), modelBytes: bytes) else { return nil }
    return Unmanaged.passRetained(Handle(__PRODUCT__(assets: assets))).toOpaque()
}

@_cdecl("__MODEL___is_downloaded")
public func __MODEL___is_downloaded(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    __PRODUCT__.isAvailable() ? 1 : 0
}

@_cdecl("__MODEL___download")
public func __MODEL___download(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let instance = core(handle) else { return -1 }
    return blockingValue { try await instance.download() } == nil ? -1 : 0
}

@_cdecl("__MODEL___run")
public func __MODEL___run(
    _ handle: UnsafeMutableRawPointer?, _ input: UnsafePointer<CChar>?, _ minimumConfidence: Double
) -> UnsafeMutableRawPointer? {
    guard let instance = core(handle), let input else { return nil }
    let text = String(cString: input)
    guard let result = blockingValue({ try await instance.run(text, minimumConfidence: minimumConfidence) })
    else { return nil }
    var w = FFIWriter()
    // Payload schema is this model's own concern; keep it in sync with the
    // decoders in packages/__MODEL__-node/node.js and the Kotlin FfiReader use.
    if let result {
        w.u32(1)
        w.string(result.label)
        w.f64(result.confidence)
    } else {
        w.u32(0)
    }
    return w.finish()
}

@_cdecl("__MODEL___destroy")
public func __MODEL___destroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<Handle>.fromOpaque(handle).release()
}

@_cdecl("__MODEL___string_free")
public func __MODEL___string_free(_ ptr: UnsafeMutableRawPointer?) { ffiFree(ptr) }
#endif
