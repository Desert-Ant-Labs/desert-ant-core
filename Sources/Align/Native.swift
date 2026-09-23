// Align's exported entry points. Symbol names are the one thing NativeBindings
// cannot share: `@_cdecl` takes a string literal and JNI derives the name from
// the Kotlin class. They are model-scoped so two models can link into one
// binary (`align_create`, `Java_ai_desertant_align_...`).

#if !os(WASI)
import DesertAnt
import NativeBindings
#if os(Android)
import Android
#endif

#if !os(Android)
@_cdecl("align_create")
public func align_create(_ modelId: UnsafePointer<CChar>?, _ cacheRoot: UnsafePointer<CChar>?,
                         _ directory: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    nativeCreate(binding: AlignBinding.self, modelId: modelId,
                 cacheRoot: cacheRoot, directory: directory)
}
#endif

#if os(Android)
@_cdecl("Java_ai_desertant_align_AlignNative_create")
public func androidCreateAlign(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                 _ modelId: jbyteArray?, _ cacheRoot: jbyteArray?,
                                 _ directory: jbyteArray?) -> jlong {
    androidCreate(AlignBinding.self, env: env, cls: cls, modelId: modelId,
                  cacheRoot: cacheRoot, directory: directory)
}

@_cdecl("Java_ai_desertant_align_AlignNative_destroy")
public func androidDestroyAlign(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                  _ handle: jlong) {
    nativeDestroy(androidPointer(handle))
}

@_cdecl("Java_ai_desertant_align_AlignNative_isDownloaded")
public func androidIsDownloadedAlign(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                       _ handle: jlong) -> jint {
    androidIsDownloaded(env, cls, handle)
}

@_cdecl("Java_ai_desertant_align_AlignNative_download")
public func androidDownloadAlign(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                   _ handle: jlong) -> jint {
    androidDownload(env, cls, handle)
}

@_cdecl("Java_ai_desertant_align_AlignNative_run")
public func androidRunAlign(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                              _ handle: jlong, _ input: jbyteArray?,
                              _ options: jbyteArray?) -> jbyteArray? {
    androidRun(env, cls, handle, input, options)
}

#endif
#endif
