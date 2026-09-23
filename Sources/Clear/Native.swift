// Clear's exported entry points. Symbol names are the one thing NativeBindings
// cannot share: `@_cdecl` takes a string literal and JNI derives the name from
// the Kotlin class. They are model-scoped so two models can link into one
// binary (`clear_create`, `Java_ai_desertant_clear_...`).

#if !os(WASI)
import DesertAnt
import NativeBindings
#if os(Android)
import Android
#endif

#if !os(Android)
@_cdecl("clear_create")
public func clear_create(_ modelId: UnsafePointer<CChar>?, _ cacheRoot: UnsafePointer<CChar>?,
                         _ directory: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    nativeCreate(binding: ClearBinding.self, modelId: modelId,
                 cacheRoot: cacheRoot, directory: directory)
}
#endif

#if os(Android)
@_cdecl("Java_ai_desertant_clear_ClearNative_create")
public func androidCreateClear(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                 _ modelId: jbyteArray?, _ cacheRoot: jbyteArray?,
                                 _ directory: jbyteArray?) -> jlong {
    androidCreate(ClearBinding.self, env: env, cls: cls, modelId: modelId,
                  cacheRoot: cacheRoot, directory: directory)
}

@_cdecl("Java_ai_desertant_clear_ClearNative_destroy")
public func androidDestroyClear(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                  _ handle: jlong) {
    nativeDestroy(androidPointer(handle))
}

@_cdecl("Java_ai_desertant_clear_ClearNative_isDownloaded")
public func androidIsDownloadedClear(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                       _ handle: jlong) -> jint {
    androidIsDownloaded(env, cls, handle)
}

@_cdecl("Java_ai_desertant_clear_ClearNative_download")
public func androidDownloadClear(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                   _ handle: jlong) -> jint {
    androidDownload(env, cls, handle)
}

@_cdecl("Java_ai_desertant_clear_ClearNative_run")
public func androidRunClear(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                              _ handle: jlong, _ input: jbyteArray?,
                              _ options: jbyteArray?) -> jbyteArray? {
    androidRun(env, cls, handle, input, options)
}

#endif
#endif
