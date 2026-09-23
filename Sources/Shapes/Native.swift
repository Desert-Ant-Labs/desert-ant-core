// Shapes' exported entry points. Symbol names are the one thing NativeBindings
// cannot share: `@_cdecl` takes a string literal and JNI derives the name from
// the Kotlin class. They are model-scoped so two models can link into one
// binary (`shapes_create`, `Java_ai_desertant_shapes_...`).

#if !os(WASI)
import DesertAnt
import NativeBindings
#if os(Android)
import Android
#endif

#if !os(Android)
@_cdecl("shapes_create")
public func shapes_create(_ modelId: UnsafePointer<CChar>?, _ cacheRoot: UnsafePointer<CChar>?,
                          _ directory: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    nativeCreate(binding: ShapesBinding.self, modelId: modelId,
                 cacheRoot: cacheRoot, directory: directory)
}
#endif

#if os(Android)
@_cdecl("Java_ai_desertant_shapes_ShapesNative_create")
public func androidCreateShapes(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                _ modelId: jbyteArray?, _ cacheRoot: jbyteArray?,
                                _ directory: jbyteArray?) -> jlong {
    androidCreate(ShapesBinding.self, env: env, cls: cls, modelId: modelId,
                  cacheRoot: cacheRoot, directory: directory)
}

@_cdecl("Java_ai_desertant_shapes_ShapesNative_destroy")
public func androidDestroyShapes(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                 _ handle: jlong) {
    nativeDestroy(androidPointer(handle))
}

@_cdecl("Java_ai_desertant_shapes_ShapesNative_isDownloaded")
public func androidIsDownloadedShapes(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                      _ handle: jlong) -> jint {
    androidIsDownloaded(env, cls, handle)
}

@_cdecl("Java_ai_desertant_shapes_ShapesNative_download")
public func androidDownloadShapes(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                  _ handle: jlong) -> jint {
    androidDownload(env, cls, handle)
}

@_cdecl("Java_ai_desertant_shapes_ShapesNative_run")
public func androidRunShapes(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                             _ handle: jlong, _ input: jbyteArray?,
                             _ options: jbyteArray?) -> jbyteArray? {
    androidRun(env, cls, handle, input, options)
}
#endif
#endif
