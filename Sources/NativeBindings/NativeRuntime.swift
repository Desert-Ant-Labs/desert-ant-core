#if !os(WASI)
import CStrings
import DesertAnt
import Dispatch

private final class NativeHandle {
    let model: any BoundModel
    /// The catalog id the host created it with, which names its run records.
    let id: String
    init(_ model: any BoundModel, id: String) {
        self.model = model
        self.id = id
    }
}

private func nativeHandle(_ handle: UnsafeMutableRawPointer?) -> NativeHandle? {
    guard let handle else { return nil }
    return Unmanaged<NativeHandle>.fromOpaque(handle).takeUnretainedValue()
}

private func model(_ handle: UnsafeMutableRawPointer?) -> (any BoundModel)? {
    nativeHandle(handle)?.model
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
    let id = string(modelId)
    guard let instance = binding.make(id: id, cacheRoot: string(cacheRoot),
                                      directory: string(directory)) else { return nil }
    return Unmanaged.passRetained(NativeHandle(instance, id: id ?? "")).toOpaque()
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
    guard let bound = nativeHandle(handle) else { return nil }
    let inputReader = FFIReader(input, inputLen)
    let optionsReader = FFIReader(options, optionsLen)
    let device = string(deviceId)
    #if os(Android)
    // The host keeps the processors each call ran on (DesertAnt.recentRuns()),
    // when it is new enough to take them.
    let recorder = hostRecordsRuns ? RunRecorder() : nil
    let clock = ContinuousClock()
    let started = clock.now
    #else
    let recorder: RunRecorder? = nil
    #endif
    let payload: [UInt8]? = blockingValue(with: bound.model) { model in
        await InferenceContext.$deviceId.withValue(device) {
            await InferenceContext.$runRecorder.withValue(recorder) {
                await model.run(input: inputReader, options: optionsReader)
            }
        }
    }
    #if os(Android)
    if let recorder {
        hostRecordRun(modelId: bound.id, record: runRecord(recorder.recorded, elapsed: clock.now - started,
                                                           succeeded: payload != nil))
    }
    #endif
    return payload.flatMap(ffiEmit)
}

#if os(Android)
/// A call's record as the host reads it (DesertAntNative.recordRun): a format
/// version, whether the call succeeded, its wall time in milliseconds, then
/// each graph's name, requested and used processor bits, and fallback code.
func runRecord(_ graphs: [GraphPlacement], elapsed: Duration, succeeded: Bool) -> [UInt8] {
    var writer = FFIWriter()
    writer.u32(1)
    writer.u32(succeeded ? 1 : 0)
    let (seconds, attoseconds) = elapsed.components
    writer.f64(Double(seconds) * 1000 + Double(attoseconds) / 1e15)
    writer.u32(graphs.count)
    for graph in graphs {
        writer.string(graph.graph)
        writer.u32(Int(graph.requested.rawValue))
        writer.u32(Int(graph.processors.rawValue))
        writer.u32(Int(graph.fallback?.rawValue ?? 0))
    }
    return writer.bytes
}
#endif

/// Block until the license requests in flight finish. The C ABI's
/// `dal_flush_licenses`, behind the SDKs' `flushLicenses()`. False when device licenses are left.
@discardableResult
public func nativeFlushLicenses() -> Bool {
    blockingValue { await LicenseFlush.shared.flushAndWait() }
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
