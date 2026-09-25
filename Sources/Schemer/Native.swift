// Schemer's exported entry points. Everything behind them is model-agnostic
// and lives in NativeBindings; this file only names the symbols, because
// symbol names are the one thing that cannot be shared: `@_cdecl` takes a
// string literal and JNI derives its name from the Kotlin class.
//
// The names are model-scoped (`schemer_create`,
// `Java_ai_desertant_schemer_...`) rather than generic, so two models can be
// linked into one binary.

#if !os(WASI)
import DesertAnt
import NativeBindings
#if os(Android)
import Android
#endif

#if !os(Android)
@_cdecl("schemer_create")
public func schemer_create(_ modelId: UnsafePointer<CChar>?, _ cacheRoot: UnsafePointer<CChar>?,
                           _ directory: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    nativeCreate(binding: SchemerBinding.self, modelId: modelId,
                 cacheRoot: cacheRoot, directory: directory)
}
#endif

#if os(Android)
@_cdecl("Java_ai_desertant_schemer_SchemerNative_create")
public func androidCreateSchemer(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                 _ modelId: jbyteArray?, _ cacheRoot: jbyteArray?,
                                 _ directory: jbyteArray?) -> jlong {
    androidCreate(SchemerBinding.self, env: env, cls: cls, modelId: modelId,
                  cacheRoot: cacheRoot, directory: directory)
}

@_cdecl("Java_ai_desertant_schemer_SchemerNative_destroy")
public func androidDestroySchemer(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                  _ handle: jlong) {
    nativeDestroy(androidPointer(handle))
}

@_cdecl("Java_ai_desertant_schemer_SchemerNative_isDownloaded")
public func androidIsDownloadedSchemer(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                       _ handle: jlong) -> jint {
    androidIsDownloaded(env, cls, handle)
}

@_cdecl("Java_ai_desertant_schemer_SchemerNative_download")
public func androidDownloadSchemer(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                   _ handle: jlong) -> jint {
    androidDownload(env, cls, handle)
}

@_cdecl("Java_ai_desertant_schemer_SchemerNative_run")
public func androidRunSchemer(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                              _ handle: jlong, _ input: jbyteArray?,
                              _ options: jbyteArray?) -> jbyteArray? {
    androidRun(env, cls, handle, input, options)
}
#endif
#endif
