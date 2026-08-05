package ai.desertant.core

/** Loads the one shared LiteRT runtime and any number of model-specific JNI libraries. */
object NativeLibraries {
    private val loaded = mutableSetOf<String>()

    @Synchronized
    fun loadModel(library: String) {
        if (!loaded.add(library)) return
        if (loaded.size == 1) System.loadLibrary("LiteRt")
        try {
            System.loadLibrary(library)
        } catch (error: Throwable) {
            loaded.remove(library)
            throw error
        }
    }
}
