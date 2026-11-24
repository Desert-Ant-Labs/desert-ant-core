#if os(Android)
import Android
import NativeBindings

@_cdecl("Java_ai_desertant_title_TitleNative_nativeSdkVersion")
public func androidSdkVersionTitle(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?) -> jbyteArray? {
    androidSdkVersion(env)
}

@_cdecl("Java_ai_desertant_title_TitleNative_create")
public func androidCreateTitle(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                               _ modelId: jbyteArray?, _ cacheRoot: jbyteArray?,
                               _ directory: jbyteArray?) -> jlong {
    androidCreate(TitleBinding.self, env: env, cls: cls, modelId: modelId,
                  cacheRoot: cacheRoot, directory: directory)
}

@_cdecl("Java_ai_desertant_title_TitleNative_destroy")
public func androidDestroyTitle(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ handle: jlong) {
    nativeDestroy(androidPointer(handle))
}

@_cdecl("Java_ai_desertant_title_TitleNative_isDownloaded")
public func androidIsDownloadedTitle(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ handle: jlong) -> jint {
    androidIsDownloaded(env, cls, handle)
}

@_cdecl("Java_ai_desertant_title_TitleNative_download")
public func androidDownloadTitle(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ handle: jlong) -> jint {
    androidDownload(env, cls, handle)
}

@_cdecl("Java_ai_desertant_title_TitleNative_run")
public func androidRunTitle(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                            _ handle: jlong, _ input: jbyteArray?, _ options: jbyteArray?) -> jbyteArray? {
    androidRun(env, cls, handle, input, options)
}
#endif
