#if !os(WASI)
import DesertAnt
import NativeBindings
#if os(Android)
import Android
#endif

#if !os(Android)
@_cdecl("face_create")
public func face_create(_ modelId: UnsafePointer<CChar>?, _ cacheRoot: UnsafePointer<CChar>?,
                        _ directory: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    nativeCreate(binding: FaceBinding.self, modelId: modelId, cacheRoot: cacheRoot, directory: directory)
}
#endif

#if os(Android)
@_cdecl("Java_ai_desertant_face_FaceNative_nativeSdkVersion")
public func androidSdkVersionFace(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?) -> jbyteArray? {
    androidSdkVersion(env)
}

@_cdecl("Java_ai_desertant_face_FaceNative_create")
public func androidCreateFace(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                              _ modelId: jbyteArray?, _ cacheRoot: jbyteArray?,
                              _ directory: jbyteArray?) -> jlong {
    androidCreate(FaceBinding.self, env: env, cls: cls, modelId: modelId, cacheRoot: cacheRoot, directory: directory)
}

@_cdecl("Java_ai_desertant_face_FaceNative_destroy")
public func androidDestroyFace(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ handle: jlong) {
    nativeDestroy(androidPointer(handle))
}

@_cdecl("Java_ai_desertant_face_FaceNative_isDownloaded")
public func androidIsDownloadedFace(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ handle: jlong) -> jint {
    androidIsDownloaded(env, cls, handle)
}

@_cdecl("Java_ai_desertant_face_FaceNative_download")
public func androidDownloadFace(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ handle: jlong) -> jint {
    androidDownload(env, cls, handle)
}

@_cdecl("Java_ai_desertant_face_FaceNative_run")
public func androidRunFace(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ handle: jlong,
                           _ input: jbyteArray?, _ options: jbyteArray?) -> jbyteArray? {
    androidRun(env, cls, handle, input, options)
}
#endif
#endif
