#if !os(WASI) && !os(Android)
import DesertAnt

@_cdecl("dal_is_downloaded")
public func dal_is_downloaded(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    nativeIsDownloaded(handle)
}

@_cdecl("dal_download")
public func dal_download(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    nativeDownload(handle)
}

// `groupId` stays in the C ABI for hosts that still pass one; it has no effect.
@_cdecl("dal_run")
public func dal_run(
    _ handle: UnsafeMutableRawPointer?,
    _ input: UnsafePointer<UInt8>?,
    _ inputLen: Int32,
    _ options: UnsafePointer<UInt8>?,
    _ optionsLen: Int32,
    _ groupId: UnsafePointer<CChar>?,
    _ deviceId: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    nativeRun(
        handle, input: input, inputLen: inputLen, options: options, optionsLen: optionsLen,
        deviceId: deviceId)
}

@_cdecl("dal_destroy")
public func dal_destroy(_ handle: UnsafeMutableRawPointer?) {
    nativeDestroy(handle)
}

@_cdecl("dal_flush_telemetry")
public func dal_flush_telemetry() {
    nativeFlushTelemetry()
}

@_cdecl("dal_buffer_free")
public func dal_buffer_free(_ pointer: UnsafeMutablePointer<CChar>?) {
    nativeBufferFree(pointer)
}

// The host's ES256 check (1 verifies, 0 not) for Linux; null removes it unless calls are in flight, whose count returns.
@_cdecl("dal_set_license_verifier")
public func dal_set_license_verifier(
    _ verify: (@convention(c) (
        UnsafePointer<UInt8>?, Int32, UnsafePointer<UInt8>?, Int32, UnsafePointer<UInt8>?, Int32
    ) -> Int32)?
) -> Int32 {
    installHostLicenseVerifier(verify)
}
#endif
