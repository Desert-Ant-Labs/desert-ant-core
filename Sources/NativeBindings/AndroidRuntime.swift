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

/// Run the model over the input and options payloads Kotlin wrote. Both cross as
/// byte arrays, so this is one entry for every modality: the audio path used to
/// decode samples here only to hand them to a typed `nativeRunAudio`, which the
/// model then re-read - the payload now goes straight through.
public func androidRun(
    _ env: UnsafeMutablePointer<JNIEnv?>,
    _ cls: jclass?,
    _ handle: jlong,
    _ input: jbyteArray?,
    _ options: jbyteArray?
) -> jbyteArray? {
    installDesertAntHostBridge(env)
    guard let inputBytes = androidOptionalBytes(env, input) else { return nil }
    let optionsBytes = androidOptionalBytes(env, options) ?? []
    let buffer = inputBytes.withUnsafeBufferPointer { input in
        optionsBytes.withUnsafeBufferPointer { options in
            nativeRun(
                androidPointer(handle),
                input: input.baseAddress, inputLen: Int32(input.count),
                options: options.baseAddress, optionsLen: Int32(options.count),
                groupId: nil, deviceId: nil)
        }
    }
    return hostTakeBuffer(env, buffer)
}

#endif
