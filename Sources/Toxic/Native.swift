// Toxic's exported entry points. Symbol names are the one thing NativeBindings
// cannot share: `@_cdecl` takes a string literal and JNI derives the name from
// the Kotlin class. They are model-scoped so two models can link into one
// binary (`toxic_create`, `Java_ai_desertant_toxic_...`).

#if !os(WASI)
import DesertAnt
import NativeBindings
#if os(Android)
import Android
#endif

#if !os(Android)
@_cdecl("toxic_create")
public func toxic_create(_ modelId: UnsafePointer<CChar>?, _ cacheRoot: UnsafePointer<CChar>?,
                        _ directory: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    nativeCreate(binding: ToxicBinding.self, modelId: modelId,
                 cacheRoot: cacheRoot, directory: directory)
}
#endif

#if os(Android)
@_cdecl("Java_ai_desertant_toxic_ToxicNative_create")
public func androidCreateToxic(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                               _ modelId: jbyteArray?, _ cacheRoot: jbyteArray?,
                               _ directory: jbyteArray?) -> jlong {
    androidCreate(ToxicBinding.self, env: env, cls: cls, modelId: modelId,
                  cacheRoot: cacheRoot, directory: directory)
}

@_cdecl("Java_ai_desertant_toxic_ToxicNative_destroy")
public func androidDestroyToxic(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                _ handle: jlong) {
    nativeDestroy(androidPointer(handle))
}

@_cdecl("Java_ai_desertant_toxic_ToxicNative_isDownloaded")
public func androidIsDownloadedToxic(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                     _ handle: jlong) -> jint {
    androidIsDownloaded(env, cls, handle)
}

@_cdecl("Java_ai_desertant_toxic_ToxicNative_download")
public func androidDownloadToxic(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                 _ handle: jlong) -> jint {
    androidDownload(env, cls, handle)
}

@_cdecl("Java_ai_desertant_toxic_ToxicNative_run")
public func androidRunToxic(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                            _ handle: jlong, _ input: jbyteArray?,
                            _ options: jbyteArray?) -> jbyteArray? {
    androidRun(env, cls, handle, input, options)
}
#endif
#endif
