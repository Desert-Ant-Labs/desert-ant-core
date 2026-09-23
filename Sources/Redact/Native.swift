// Redact's exported entry points. Symbol names are the one thing NativeBindings
// cannot share: `@_cdecl` takes a string literal and JNI derives the name from
// the Kotlin class. They are model-scoped so two models can link into one
// binary (`redact_create`, `Java_ai_desertant_redact_...`).

#if !os(WASI)
import DesertAnt
import NativeBindings
#if os(Android)
import Android
#endif

#if !os(Android)
@_cdecl("redact_create")
public func redact_create(_ modelId: UnsafePointer<CChar>?, _ cacheRoot: UnsafePointer<CChar>?,
                         _ directory: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    nativeCreate(binding: RedactBinding.self, modelId: modelId,
                 cacheRoot: cacheRoot, directory: directory)
}
#endif

#if os(Android)
@_cdecl("Java_ai_desertant_redact_RedactNative_create")
public func androidCreateRedact(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                 _ modelId: jbyteArray?, _ cacheRoot: jbyteArray?,
                                 _ directory: jbyteArray?) -> jlong {
    androidCreate(RedactBinding.self, env: env, cls: cls, modelId: modelId,
                  cacheRoot: cacheRoot, directory: directory)
}

@_cdecl("Java_ai_desertant_redact_RedactNative_destroy")
public func androidDestroyRedact(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                  _ handle: jlong) {
    nativeDestroy(androidPointer(handle))
}

@_cdecl("Java_ai_desertant_redact_RedactNative_isDownloaded")
public func androidIsDownloadedRedact(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                       _ handle: jlong) -> jint {
    androidIsDownloaded(env, cls, handle)
}

@_cdecl("Java_ai_desertant_redact_RedactNative_download")
public func androidDownloadRedact(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                   _ handle: jlong) -> jint {
    androidDownload(env, cls, handle)
}

@_cdecl("Java_ai_desertant_redact_RedactNative_run")
public func androidRunRedact(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                              _ handle: jlong, _ input: jbyteArray?,
                              _ options: jbyteArray?) -> jbyteArray? {
    androidRun(env, cls, handle, input, options)
}
#endif
#endif
