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

public func nativeRun(
    _ handle: UnsafeMutableRawPointer?,
    text: UnsafePointer<CChar>?,
    options: UnsafePointer<UInt8>?,
    optionsLen: Int32,
    groupId: UnsafePointer<CChar>?,
    deviceId: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let model = model(handle), let text = string(text) else { return nil }
    let reader = FFIReader(options, optionsLen)
    let group = string(groupId)
    let device = string(deviceId)
    let payload: [UInt8]? = blockingValue {
        await InferenceContext.$deviceId.withValue(device) {
            await InferenceContext.withCallGroup(id: group) {
                await model.run(text: text, options: reader)
            }
        }
    }
    return payload.flatMap(ffiEmit)
}

public func nativeRunAudio(
    _ handle: UnsafeMutableRawPointer?,
    samples: UnsafePointer<Float>?,
    sampleCount: Int32,
    sampleRate: Double,
    options: UnsafePointer<UInt8>?,
    optionsLen: Int32,
    groupId: UnsafePointer<CChar>?,
    deviceId: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let model = model(handle), let samples, sampleCount > 0 else { return nil }
    let audio = Array(UnsafeBufferPointer(start: samples, count: Int(sampleCount)))
    let reader = FFIReader(options, optionsLen)
    let group = string(groupId)
    let device = string(deviceId)
    let payload: [UInt8]? = blockingValue {
        await InferenceContext.$deviceId.withValue(device) {
            await InferenceContext.withCallGroup(id: group) {
                await model.run(audio: audio, sampleRate: sampleRate, options: reader)
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
