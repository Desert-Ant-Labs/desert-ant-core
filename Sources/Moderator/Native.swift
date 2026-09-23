// Moderator's exported entry points. Everything behind them is model-agnostic and
// lives in NativeBindings; this file only names the symbols, because symbol
// names are the one thing that cannot be shared: `@_cdecl` takes a string
// literal and JNI derives its name from the Kotlin class.
//
// The names are model-scoped (`moderator_create`, `Java_ai_desertant_moderator_...`)
// rather than generic, so two models can be linked into one binary - which is
// what lets a model be a single target instead of a separate native one.

#if !os(WASI)
import DesertAnt
import NativeBindings
#if os(Android)
import Android
#endif

#if !os(Android)
@_cdecl("moderator_create")
public func moderator_create(_ modelId: UnsafePointer<CChar>?, _ cacheRoot: UnsafePointer<CChar>?,
                          _ directory: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    nativeCreate(binding: ModeratorBinding.self, modelId: modelId,
                 cacheRoot: cacheRoot, directory: directory)
}
#endif

#if os(Android)
@_cdecl("Java_ai_desertant_moderator_ModeratorNative_create")
public func androidCreateModerator(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                _ modelId: jbyteArray?, _ cacheRoot: jbyteArray?,
                                _ directory: jbyteArray?) -> jlong {
    androidCreate(ModeratorBinding.self, env: env, cls: cls, modelId: modelId,
                  cacheRoot: cacheRoot, directory: directory)
}

@_cdecl("Java_ai_desertant_moderator_ModeratorNative_destroy")
public func androidDestroyModerator(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                 _ handle: jlong) {
    nativeDestroy(androidPointer(handle))
}

@_cdecl("Java_ai_desertant_moderator_ModeratorNative_isDownloaded")
public func androidIsDownloadedModerator(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                      _ handle: jlong) -> jint {
    androidIsDownloaded(env, cls, handle)
}

@_cdecl("Java_ai_desertant_moderator_ModeratorNative_download")
public func androidDownloadModerator(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                  _ handle: jlong) -> jint {
    androidDownload(env, cls, handle)
}

@_cdecl("Java_ai_desertant_moderator_ModeratorNative_run")
public func androidRunModerator(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                             _ handle: jlong, _ input: jbyteArray?,
                             _ options: jbyteArray?) -> jbyteArray? {
    androidRun(env, cls, handle, input, options)
}
#endif
#endif
