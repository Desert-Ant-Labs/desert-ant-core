#if !os(WASI)
import DesertAnt
// For the handle's mutex, the same platform shims LiteRTSession uses.
#if os(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The model behind the opaque handle, plus the last error it failed with.
///
/// The C ABI reports failure as a NULL buffer or a non-zero code, which cannot
/// say *why*. Hosts read the reason back with `dal_last_error`, so a caller sees
/// "HTTP 403" or "no space left on device" instead of a generic failure. Locked
/// because the host may call from any thread, the same way `LiteRTSession` is.
private final class NativeHandle: @unchecked Sendable {
    let model: any BoundModel
    private var lastError: String?
    private var lock = pthread_mutex_t()

    init(_ model: any BoundModel) {
        self.model = model
        pthread_mutex_init(&lock, nil)
    }

    deinit { pthread_mutex_destroy(&lock) }

    func record(_ message: String) {
        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }
        lastError = message
    }

    func takeLastError() -> String? {
        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }
        return lastError
    }
}

private func handle(_ pointer: UnsafeMutableRawPointer?) -> NativeHandle? {
    guard let pointer else { return nil }
    return Unmanaged<NativeHandle>.fromOpaque(pointer).takeUnretainedValue()
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

public func nativeDownload(_ pointer: UnsafeMutableRawPointer?) -> Int32 {
    guard let handle = handle(pointer) else { return -1 }
    let failure: String? = blockingValue(with: handle.model) { model in
        do {
            try await model.download(progress: { _ in })
            return nil
        } catch { return String(describing: error) }
    }
    guard let failure else { return 0 }
    handle.record(failure)
    return -1
}

/// Run the model over its own input and options payloads (see `ModelBinding`),
/// returning its own result payload. One entry for every modality: what the input
/// bytes mean is the model's business, so a new kind of model adds no symbol here.
public func nativeRun(
    _ pointer: UnsafeMutableRawPointer?,
    input: UnsafePointer<UInt8>?,
    inputLen: Int32,
    options: UnsafePointer<UInt8>?,
    optionsLen: Int32,
    groupId: UnsafePointer<CChar>?,
    deviceId: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let handle = handle(pointer) else { return nil }
    let inputReader = FFIReader(input, inputLen)
    let optionsReader = FFIReader(options, optionsLen)
    let group = string(groupId)
    let device = string(deviceId)
    let outcome: RunOutcome = blockingValue(with: handle.model) { model in
        await InferenceContext.$deviceId.withValue(device) {
            await InferenceContext.withCallGroup(id: group) {
                do { return .ok(try await model.run(input: inputReader, options: optionsReader)) } catch {
                    return .failed(String(describing: error))
                }
            }
        }
    }
    switch outcome {
    case .ok(let payload): return ffiEmit(payload)
    case .failed(let message):
        handle.record(message)
        return nil
    }
}

/// `blockingValue` needs a `Sendable` result and the existential `any Error` is
/// not one, so the reason crosses the boundary already rendered.
private enum RunOutcome: Sendable {
    case ok([UInt8])
    case failed(String)
}

/// The reason the last `dal_run`/`dal_download` on this handle failed, as an
/// `FFIWriter` string payload (freed with `dal_buffer_free`), or NULL if the
/// handle has not failed. Additive: hosts that never call it are unaffected.
public func nativeLastError(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    guard let message = handle(pointer)?.takeLastError() else { return nil }
    var w = FFIWriter()
    w.string(message)
    return ffiEmit(w.bytes)
}

public func nativeDestroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<NativeHandle>.fromOpaque(handle).release()
}

public func nativeBufferFree(_ pointer: UnsafeMutablePointer<CChar>?) {
    ffiFree(pointer)
}
#endif
