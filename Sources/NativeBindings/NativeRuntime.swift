#if !os(WASI)
import CStrings
import DesertAnt
import Dispatch

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
    deviceId: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let model = model(handle) else { return nil }
    let inputReader = FFIReader(input, inputLen)
    let optionsReader = FFIReader(options, optionsLen)
    let device = string(deviceId)
    let payload: [UInt8]? = blockingValue(with: model) { model in
        await InferenceContext.$deviceId.withValue(device) {
            await model.run(input: inputReader, options: optionsReader)
        }
    }
    return payload.flatMap(ffiEmit)
}

/// Block until the license requests in flight finish. The C ABI's
/// `dal_flush_telemetry`, behind the SDKs' `flushTelemetry()`.
public func nativeFlushTelemetry() {
    blockingValue { await TelemetryDebug.shared.flushAndWait() }
}

public func nativeDestroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<NativeHandle>.fromOpaque(handle).release()
}

public typealias HostLog = @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

private let hostLogLock = DispatchSemaphore(value: 1)
private nonisolated(unsafe) var hostLogCalls: Int32 = 0

public func nativeSetLogLevel(_ level: Int32) -> Int32 {
    guard let level = LogLevel(rawValue: Int(level)) else { return -1 }
    Log.level = level
    return 0
}

// Removal is refused while a call is in flight and returns that count, so an
// exiting host can drain them first (a koffi callback from a core thread waits
// for the host's event loop).
public func nativeSetLogger(_ log: HostLog?) -> Int32 {
    hostLogLock.wait()
    defer { hostLogLock.signal() }
    if log == nil, hostLogCalls > 0 { return hostLogCalls }
    guard let log else {
        Log.handler = nil
        return 0
    }
    Log.handler = { level, source, message in
        hostLogLock.wait()
        hostLogCalls += 1
        hostLogLock.signal()
        defer {
            hostLogLock.wait()
            hostLogCalls -= 1
            hostLogLock.signal()
        }
        source.withCString { source in
            message.withCString { message in
                log(Int32(level.rawValue), source, message)
            }
        }
    }
    return 0
}

public func nativeBufferFree(_ pointer: UnsafeMutablePointer<CChar>?) {
    ffiFree(pointer)
}
#endif
