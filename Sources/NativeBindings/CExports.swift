#if !os(WASI) && !os(Android)
import CStrings
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

// 1 when no device license is left in the queue, 0 when some are.
@_cdecl("dal_flush_licenses")
public func dal_flush_licenses() -> Int32 {
    nativeFlushLicenses() ? 1 : 0
}

// The API key from `DesertAnt.configure` in JavaScript.
@_cdecl("dal_configure")
public func dal_configure(_ apiKey: UnsafePointer<CChar>) {
    DesertAnt.configure(apiKey: decodeCString(apiKey))
}

// The device id secret from `DesertAnt.configure` in JavaScript, or NULL for none.
@_cdecl("dal_configure_device_id_secret")
public func dal_configure_device_id_secret(_ secret: UnsafePointer<CChar>?) {
    DesertAnt.configure(deviceIdSecret: secret.map(decodeCString))
}

@_cdecl("dal_buffer_free")
public func dal_buffer_free(_ pointer: UnsafeMutablePointer<CChar>?) {
    nativeBufferFree(pointer)
}

// The log level, as a LogLevel raw value (0 debug to 4 off). -1 for a value that is none of them.
@_cdecl("dal_set_log_level")
public func dal_set_log_level(_ level: Int32) -> Int32 {
    nativeSetLogLevel(level)
}

// The host's logger, receiving every message (level, source, message); null removes it unless calls are in flight, whose count returns.
@_cdecl("dal_set_logger")
public func dal_set_logger(
    _ log: (@convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void)?
) -> Int32 {
    nativeSetLogger(log)
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
