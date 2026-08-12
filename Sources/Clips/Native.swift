// Clips's exported entry points. Everything behind them is model-agnostic and
// lives in NativeBindings; this file only names the symbols, because symbol
// names are the one thing that cannot be shared: `@_cdecl` takes a string
// literal and JNI derives its name from the Kotlin class.
//
// The names are model-scoped (`clips_create`, `Java_ai_desertant_clip_...`)
// rather than generic, so two models can be linked into one binary - which is
// what lets a model be a single target instead of a separate native one.

#if !os(WASI)
import DesertAnt
import NativeBindings
#if os(Android)
import Android
#endif

#if !os(Android)
@_cdecl("clips_create")
public func clips_create(_ modelId: UnsafePointer<CChar>?, _ cacheRoot: UnsafePointer<CChar>?,
                        _ directory: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    nativeCreate(binding: ClipBinding.self, modelId: modelId,
                 cacheRoot: cacheRoot, directory: directory)
}
#endif

#if os(Android)
@_cdecl("Java_ai_desertant_clip_ClipNative_create")
public func androidCreateClip(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                              _ modelId: jbyteArray?, _ cacheRoot: jbyteArray?,
                              _ directory: jbyteArray?) -> jlong {
    androidCreate(ClipBinding.self, env: env, cls: cls, modelId: modelId,
                  cacheRoot: cacheRoot, directory: directory)
}

@_cdecl("Java_ai_desertant_clip_ClipNative_destroy")
public func androidDestroyClip(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                               _ handle: jlong) {
    nativeDestroy(androidPointer(handle))
}

@_cdecl("Java_ai_desertant_clip_ClipNative_isDownloaded")
public func androidIsDownloadedClip(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                    _ handle: jlong) -> jint {
    androidIsDownloaded(env, cls, handle)
}

@_cdecl("Java_ai_desertant_clip_ClipNative_download")
public func androidDownloadClip(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                _ handle: jlong) -> jint {
    androidDownload(env, cls, handle)
}

@_cdecl("Java_ai_desertant_clip_ClipNative_run")
public func androidRunClip(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                           _ handle: jlong, _ input: jbyteArray?,
                           _ options: jbyteArray?) -> jbyteArray? {
    androidRun(env, cls, handle, input, options)
}
#endif
#endif
