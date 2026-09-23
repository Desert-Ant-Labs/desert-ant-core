// Uhm's exported entry points. Symbol names are the one thing NativeBindings
// cannot share: `@_cdecl` takes a string literal and JNI derives the name from
// the Kotlin class. They are model-scoped so two models can link into one
// binary (`uhm_create`, `Java_ai_desertant_uhm_...`).

#if !os(WASI)
import DesertAnt
import NativeBindings
#if os(Android)
import Android
#endif

#if !os(Android)
@_cdecl("uhm_create")
public func uhm_create(_ modelId: UnsafePointer<CChar>?, _ cacheRoot: UnsafePointer<CChar>?,
                       _ directory: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    nativeCreate(binding: UhmBinding.self, modelId: modelId,
                 cacheRoot: cacheRoot, directory: directory)
}
#endif

#if os(Android)
@_cdecl("Java_ai_desertant_uhm_UhmNative_create")
public func androidCreateUhm(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                             _ modelId: jbyteArray?, _ cacheRoot: jbyteArray?,
                             _ directory: jbyteArray?) -> jlong {
    androidCreate(UhmBinding.self, env: env, cls: cls, modelId: modelId,
                  cacheRoot: cacheRoot, directory: directory)
}

@_cdecl("Java_ai_desertant_uhm_UhmNative_destroy")
public func androidDestroyUhm(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                              _ handle: jlong) {
    nativeDestroy(androidPointer(handle))
}

@_cdecl("Java_ai_desertant_uhm_UhmNative_isDownloaded")
public func androidIsDownloadedUhm(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                   _ handle: jlong) -> jint {
    androidIsDownloaded(env, cls, handle)
}

@_cdecl("Java_ai_desertant_uhm_UhmNative_download")
public func androidDownloadUhm(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                               _ handle: jlong) -> jint {
    androidDownload(env, cls, handle)
}

@_cdecl("Java_ai_desertant_uhm_UhmNative_run")
public func androidRunUhm(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                          _ handle: jlong, _ input: jbyteArray?,
                          _ options: jbyteArray?) -> jbyteArray? {
    androidRun(env, cls, handle, input, options)
}

#endif
#endif
