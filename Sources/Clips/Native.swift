// Clips's exported entry points. Symbol names are the one thing NativeBindings
// cannot share: `@_cdecl` takes a string literal and JNI derives the name from
// the Kotlin class. They are model-scoped so two models can link into one
// binary (`clips_create`, `Java_ai_desertant_clip_...`).

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
