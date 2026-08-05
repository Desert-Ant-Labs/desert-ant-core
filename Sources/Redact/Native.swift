// Redact's exported entry points. Everything behind them is model-agnostic and
// lives in NativeBindings; this file only names the symbols, because symbol
// names are the one thing that cannot be shared: `@_cdecl` takes a string
// literal and JNI derives its name from the Kotlin class.
//
// The names are model-scoped (`redact_create`, `Java_ai_desertant_redact_...`) rather
// than generic, so two models can be linked into one binary - which is what lets
// a model be a single target instead of a separate native one.

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
                              _ handle: jlong, _ text: jbyteArray?,
                              _ options: jbyteArray?) -> jbyteArray? {
    androidRun(env, cls, handle, text, options)
}
#endif
#endif
