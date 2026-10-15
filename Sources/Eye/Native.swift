// Eye's exported entry points. Symbol names are the one thing NativeBindings
// cannot share: `@_cdecl` takes a string literal and JNI derives the name from
// the Kotlin class. They are model-scoped so two models can link into one
// binary (`eye_create`, `Java_ai_desertant_eye_...`).

#if !os(WASI)
import DesertAnt
import NativeBindings
#if os(Android)
import Android
#endif

#if !os(Android)
@_cdecl("eye_create")
public func eye_create(_ modelId: UnsafePointer<CChar>?, _ cacheRoot: UnsafePointer<CChar>?,
                          _ directory: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    nativeCreate(binding: EyeBinding.self, modelId: modelId,
                 cacheRoot: cacheRoot, directory: directory)
}
#endif

#if os(Android)
@_cdecl("Java_ai_desertant_eye_EyeNative_create")
public func androidCreateEye(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                _ modelId: jbyteArray?, _ cacheRoot: jbyteArray?,
                                _ directory: jbyteArray?) -> jlong {
    androidCreate(EyeBinding.self, env: env, cls: cls, modelId: modelId,
                  cacheRoot: cacheRoot, directory: directory)
}

@_cdecl("Java_ai_desertant_eye_EyeNative_destroy")
public func androidDestroyEye(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                 _ handle: jlong) {
    nativeDestroy(androidPointer(handle))
}

@_cdecl("Java_ai_desertant_eye_EyeNative_isDownloaded")
public func androidIsDownloadedEye(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                      _ handle: jlong) -> jint {
    androidIsDownloaded(env, cls, handle)
}

@_cdecl("Java_ai_desertant_eye_EyeNative_download")
public func androidDownloadEye(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                  _ handle: jlong) -> jint {
    androidDownload(env, cls, handle)
}

@_cdecl("Java_ai_desertant_eye_EyeNative_run")
public func androidRunEye(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                             _ handle: jlong, _ input: jbyteArray?,
                             _ options: jbyteArray?) -> jbyteArray? {
    androidRun(env, cls, handle, input, options)
}
#endif
#endif
