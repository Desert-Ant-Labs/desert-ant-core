#if !os(WASI) && !os(Android)

@_cdecl("dal_is_downloaded")
public func dal_is_downloaded(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    nativeIsDownloaded(handle)
}

@_cdecl("dal_download")
public func dal_download(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    nativeDownload(handle)
}

@_cdecl("dal_run")
public func dal_run(
    _ handle: UnsafeMutableRawPointer?,
    _ text: UnsafePointer<CChar>?,
    _ options: UnsafePointer<UInt8>?,
    _ optionsLen: Int32,
    _ groupId: UnsafePointer<CChar>?,
    _ deviceId: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    nativeRun(
        handle, text: text, options: options, optionsLen: optionsLen,
        groupId: groupId, deviceId: deviceId)
}

@_cdecl("dal_run_audio")
public func dal_run_audio(
    _ handle: UnsafeMutableRawPointer?,
    _ samples: UnsafePointer<Float>?,
    _ sampleCount: Int32,
    _ sampleRate: Double,
    _ options: UnsafePointer<UInt8>?,
    _ optionsLen: Int32,
    _ groupId: UnsafePointer<CChar>?,
    _ deviceId: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    nativeRunAudio(
        handle, samples: samples, sampleCount: sampleCount,
        sampleRate: sampleRate, options: options, optionsLen: optionsLen,
        groupId: groupId, deviceId: deviceId)
}

@_cdecl("dal_destroy")
public func dal_destroy(_ handle: UnsafeMutableRawPointer?) {
    nativeDestroy(handle)
}

@_cdecl("dal_buffer_free")
public func dal_buffer_free(_ pointer: UnsafeMutablePointer<CChar>?) {
    nativeBufferFree(pointer)
}
#endif
