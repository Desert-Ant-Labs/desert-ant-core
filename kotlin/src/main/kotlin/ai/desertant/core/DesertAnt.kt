package ai.desertant.core

/**
 * Process-wide Desert Ant configuration, for hosts where an environment
 * variable is not a natural fit (an Android app has no launch environment of
 * its own). Set once at launch, before the first model call:
 *
 * ```kotlin
 * DesertAnt.apiKey = "pk_live_..."
 * ```
 *
 * Mirrors core's Swift `DesertAnt.apiKey`, and covers every model in the app.
 * The key is read when a model builds its usage client, on its first call, so
 * a value set after that does not re-attribute it. Null (the default) or blank
 * means unset, and attribution uses the app identity instead.
 */
object DesertAnt {
    /** The publishable API key used for usage attribution. Null means unset. */
    @JvmStatic
    @Volatile
    var apiKey: String? = null
}
