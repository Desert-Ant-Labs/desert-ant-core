#if os(Android)
import Android
import DesertAnt

public func androidHandle(_ pointer: UnsafeMutableRawPointer?) -> jlong {
    jlong(Int(bitPattern: pointer))
}

public func androidPointer(_ handle: jlong) -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(bitPattern: Int(handle))
}

public func androidOptionalBytes(_ env: HostEnv, _ array: jbyteArray?) -> [UInt8]? {
    hostCopyBytes(env, array).flatMap { $0.isEmpty ? nil : $0 }
}

public func androidCreate(
    _ binding: any ModelBinding.Type,
    env: UnsafeMutablePointer<JNIEnv?>,
    cls: jclass?,
    modelId: jbyteArray?,
    cacheRoot: jbyteArray?,
    directory: jbyteArray?
) -> jlong {
    installDesertAntHostBridge(env)
    return withHostCText(androidOptionalBytes(env, modelId)) { id in
        withHostCText(androidOptionalBytes(env, cacheRoot)) { root in
            withHostCText(androidOptionalBytes(env, directory)) { dir in
                androidHandle(
                    nativeCreate(binding: binding, modelId: id, cacheRoot: root, directory: dir))
            }
        }
    }
}

public func androidIsDownloaded(
    _ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ handle: jlong
) -> jint {
    installDesertAntHostBridge(env)
    return jint(nativeIsDownloaded(androidPointer(handle)))
}

public func androidDownload(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ handle: jlong)
    -> jint
{
    installDesertAntHostBridge(env)
    return jint(nativeDownload(androidPointer(handle)))
}

public func androidRun(
    _ env: UnsafeMutablePointer<JNIEnv?>,
    _ cls: jclass?,
    _ handle: jlong,
    _ text: jbyteArray?,
    _ options: jbyteArray?
) -> jbyteArray? {
    installDesertAntHostBridge(env)
    guard let bytes = hostCopyBytes(env, text) else { return nil }
    let payload = androidOptionalBytes(env, options) ?? []
    let buffer = withHostCText(bytes) { text in
        payload.withUnsafeBufferPointer { options in
            nativeRun(
                androidPointer(handle), text: text, options: options.baseAddress,
                optionsLen: Int32(options.count), groupId: nil, deviceId: nil)
        }
    }
    return hostTakeBuffer(env, buffer)
}

public func androidRunAudio(
    _ env: UnsafeMutablePointer<JNIEnv?>,
    _ cls: jclass?,
    _ handle: jlong,
    _ audio: jbyteArray?,
    _ options: jbyteArray?
) -> jbyteArray? {
    installDesertAntHostBridge(env)
    guard let bytes = androidOptionalBytes(env, audio) else { return nil }
    var reader = FFIReader(bytes)
    let samples = reader.f32Array()
    let sampleRate = reader.f64()
    guard !samples.isEmpty, sampleRate > 0 else { return nil }
    let payload = androidOptionalBytes(env, options) ?? []
    let buffer = samples.withUnsafeBufferPointer { samples in
        payload.withUnsafeBufferPointer { options in
            nativeRunAudio(
                androidPointer(handle), samples: samples.baseAddress,
                sampleCount: Int32(samples.count), sampleRate: sampleRate,
                options: options.baseAddress, optionsLen: Int32(options.count),
                groupId: nil, deviceId: nil)
        }
    }
    return hostTakeBuffer(env, buffer)
}
#endif
