#if !os(WASI)
import DesertAnt

private final class NativeHandle {
    let model: any BoundModel
    init(_ model: any BoundModel) { self.model = model }
}

private func model(_ handle: UnsafeMutableRawPointer?) -> (any BoundModel)? {
    guard let handle else { return nil }
    return Unmanaged<NativeHandle>.fromOpaque(handle).takeUnretainedValue().model
}

private func string(_ pointer: UnsafePointer<CChar>?) -> String? {
    pointer.map { String(cString: $0) }
}

public func nativeCreate(
    binding: any ModelBinding.Type,
    modelId: UnsafePointer<CChar>?,
    cacheRoot: UnsafePointer<CChar>?,
    directory: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    guard string(modelId) == binding.id else { return nil }
    let instance = binding.make(cacheRoot: string(cacheRoot), directory: string(directory))
    return Unmanaged.passRetained(NativeHandle(instance)).toOpaque()
}

public func nativeIsDownloaded(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    (model(handle)?.isDownloaded() ?? false) ? 1 : 0
}

public func nativeDownload(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let model = model(handle) else { return -1 }
    let ok: Bool = blockingValue {
        do {
            try await model.download(progress: { _ in })
            return true
        } catch { return false }
    }
    return ok ? 0 : -1
}

/// Run the model over its own input and options payloads (see `ModelBinding`),
/// returning its own result payload. One entry for every modality: what the input
/// bytes mean is the model's business, so a new kind of model adds no symbol here.
public func nativeRun(
    _ handle: UnsafeMutableRawPointer?,
    input: UnsafePointer<UInt8>?,
    inputLen: Int32,
    options: UnsafePointer<UInt8>?,
    optionsLen: Int32,
    groupId: UnsafePointer<CChar>?,
    deviceId: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let model = model(handle) else { return nil }
    let inputReader = FFIReader(input, inputLen)
    let optionsReader = FFIReader(options, optionsLen)
    let group = string(groupId)
    let device = string(deviceId)
    let payload: [UInt8]? = blockingValue {
        await InferenceContext.$deviceId.withValue(device) {
            await InferenceContext.withCallGroup(id: group) {
                await model.run(input: inputReader, options: optionsReader)
            }
        }
    }
    return payload.flatMap(ffiEmit)
}

public func nativeDestroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<NativeHandle>.fromOpaque(handle).release()
}

public func nativeBufferFree(_ pointer: UnsafeMutablePointer<CChar>?) {
    ffiFree(pointer)
}
#endif
