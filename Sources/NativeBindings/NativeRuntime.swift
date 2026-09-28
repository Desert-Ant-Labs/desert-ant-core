#if !os(WASI)
import CStrings
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
    pointer.map(decodeCString)
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
    let ok: Bool = blockingValue(with: model) { model in
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
    let owner = UInt(bitPattern: handle)
    let payload: [UInt8]? = blockingValue(with: model) { model in
        await InferenceContext.$owner.withValue(owner) {
            await InferenceContext.$deviceId.withValue(device) {
                await InferenceContext.withCallGroup(id: group) {
                    await model.run(input: inputReader, options: optionsReader)
                }
            }
        }
    }
    return payload.flatMap(ffiEmit)
}

/// Force every tracked session to emit usage now (bypassing the debounce and the
/// re-emit window) and block until the sends complete. The C ABI's
/// `dal_flush_telemetry`, behind the SDKs' `flushTelemetry()`.
public func nativeFlushTelemetry() {
    blockingValue { await TelemetryDebug.shared.flushAndWait() }
}

/// Flushes live sessions and waits for usage sends, for at most `timeoutMs`. The C ABI's `dal_await_usage_sends`, run as a Node host exits.
public func nativeAwaitUsageSends(timeoutMs: Int32) {
    flushAndWaitForUsage(timeoutMs: Int(timeoutMs))
}

/// The retained handle, carried into the task that releases it.
private struct RetainedHandle: @unchecked Sendable {
    let handle: Unmanaged<NativeHandle>
}

public func nativeDestroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    let owner = UInt(bitPattern: handle)
    let retained = RetainedHandle(handle: Unmanaged<NativeHandle>.fromOpaque(handle))
    // Never blocks the caller: the handle stays alive until its sessions are suspended.
    SessionOwners.shared.suspendAll(owner: owner) { retained.handle.release() }
}

public func nativeBufferFree(_ pointer: UnsafeMutablePointer<CChar>?) {
    ffiFree(pointer)
}
#endif
