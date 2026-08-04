#if !os(WASI)
import DesertAnt

// The SDK's C ABI: one set of symbols for every model, called by the JNI entry
// points in `AndroidJNI.swift` and by any other host language (koffi on Node,
// P/Invoke, cgo, …). Kept Foundation-free so the Android build ships without the
// ~50 MB Foundation/ICU stack. Instance-based, mirroring the Swift SDK: one
// handle per loaded model.
//
//   dal_create(modelId, cacheRootUTF8, dirUTF8|NULL)          -> handle | NULL
//   dal_create_from_files(modelId, files,len, modelPath|NULL)  -> handle | NULL
//   dal_is_downloaded(handle)                                  -> 0/1
//   dal_download(handle)                                       -> 0/-1  (blocks)
//   dal_run(handle, textUTF8, options,len, groupId|NULL, deviceId|NULL)
//                                                              -> buffer | NULL
//   dal_destroy(handle)
//   dal_buffer_free(ptr)
//
// `modelId` is the catalog id ("emo", "redact", …). Options in and results out
// are `FFIBuffer` payloads whose schema belongs to the model (see each model's
// `Binding.swift`), which is what lets these symbols be model-agnostic: adding a
// model adds no C symbol, no native library, and no host-side plumbing.
//
// Buffers returned here are malloc'd; the host frees them with `dal_buffer_free`.
// The async core API is bridged synchronously, since callers are host-language
// worker threads.

/// A retained box so the opaque handle keeps the model alive.
private final class Handle {
    let model: any BoundModel
    init(_ model: any BoundModel) { self.model = model }
}

private func model(_ handle: UnsafeMutableRawPointer?) -> (any BoundModel)? {
    guard let handle else { return nil }
    return Unmanaged<Handle>.fromOpaque(handle).takeUnretainedValue().model
}

private func retain(_ model: any BoundModel) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(Handle(model)).toOpaque()
}

private func string(_ pointer: UnsafePointer<CChar>?) -> String? {
    pointer.map { String(cString: $0) }
}

/// Create a model against the store. `cacheRoot` is the app cache dir (the base
/// for the managed nested layout). `directory` is an explicit model directory
/// (adopt files there, else download into it), or NULL for the managed layout
/// under `cacheRoot`. Loading is lazy, like the Swift SDK. NULL if `modelId` is
/// not a model this library was built with.
@_cdecl("dal_create")
public func dal_create(
    _ modelId: UnsafePointer<CChar>?,
    _ cacheRoot: UnsafePointer<CChar>?,
    _ directory: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    guard let id = string(modelId), let binding = binding(for: id) else { return nil }
    return retain(binding.make(cacheRoot: string(cacheRoot), directory: string(directory)))
}

/// Create a model from files the host already has (Android classpath resources,
/// an app bundle, a self-hosted directory). `files` is an `FFIWriter` payload:
/// `u32 count`, then per file a length-prefixed name and a length-prefixed blob,
/// named as in the catalog manifest. When `modelPath` is non-NULL the runnable
/// artifact is read from that path instead (mmap, so a multi-megabyte artifact is
/// not copied through the FFI) and only the sidecars need to be in `files`.
@_cdecl("dal_create_from_files")
public func dal_create_from_files(
    _ modelId: UnsafePointer<CChar>?,
    _ files: UnsafePointer<UInt8>?, _ filesLen: Int32,
    _ modelPath: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    guard let id = string(modelId), let binding = binding(for: id) else { return nil }
    var reader = FFIReader(files, filesLen)
    var named: [String: [UInt8]] = [:]
    for _ in 0..<reader.u32() {
        let name = reader.string()
        let blob = reader.blob()
        guard !name.isEmpty else { return nil }
        named[name] = blob
    }
    guard let model = try? binding.make(files: named, modelPath: string(modelPath)) else { return nil }
    return retain(model)
}

/// Whether the model is usable with no network.
@_cdecl("dal_is_downloaded")
public func dal_is_downloaded(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    (model(handle)?.isDownloaded() ?? false) ? 1 : 0
}

/// Download and verify the model ahead of time (blocks). 0 on success, -1 on
/// failure.
@_cdecl("dal_download")
public func dal_download(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let model = model(handle) else { return -1 }
    let ok: Bool = blockingValue {
        do { try await model.download(); return true } catch { return false }
    }
    return ok ? 0 : -1
}

/// Run the model over `text`. `options` is the model's own payload (NULL/0 means
/// its defaults), and the result is the model's own payload - see that model's
/// `Binding.swift` for both schemas. NULL if the run failed.
///
/// `groupId` attributes usage to a shared call group: every run sharing an id
/// bills as one call (release it with `dal_call_group_end`). `deviceId` bills to a
/// specific end user, for multi-tenant hosts serving many users. Both are
/// optional - pass NULL to omit either. Android omits both and resolves its
/// device through the host bridge; the Node build uses them.
@_cdecl("dal_run")
public func dal_run(
    _ handle: UnsafeMutableRawPointer?,
    _ text: UnsafePointer<CChar>?,
    _ options: UnsafePointer<UInt8>?, _ optionsLen: Int32,
    _ groupId: UnsafePointer<CChar>?,
    _ deviceId: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let model = model(handle), let input = string(text) else { return nil }
    let reader = FFIReader(options, optionsLen)
    let group = string(groupId)
    let device = string(deviceId)
    let payload: [UInt8]? = blockingValue {
        await InferenceContext.$deviceId.withValue(device) {
            await InferenceContext.withCallGroup(id: group) {
                await model.run(text: input, options: reader)
            }
        }
    }
    return payload.flatMap(ffiEmit)
}

/// Release a handle from `dal_create`/`dal_create_from_files`.
@_cdecl("dal_destroy")
public func dal_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<Handle>.fromOpaque(handle).release()
}

/// Free a buffer returned by `dal_run`.
@_cdecl("dal_buffer_free")
public func dal_buffer_free(_ pointer: UnsafeMutablePointer<CChar>?) {
    ffiFree(pointer)
}
#endif
