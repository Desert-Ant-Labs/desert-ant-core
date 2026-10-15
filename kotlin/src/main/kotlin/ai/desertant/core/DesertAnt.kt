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
 * The key is read on each model load, when the SDK requests or activates that
 * model's license. Null (the default) or blank means unset, and the license is
 * activated without a key.
 */
object DesertAnt {
    /** The publishable API key sent with license grants and activations. Null means unset. */
    @JvmStatic
    @Volatile
    var apiKey: String? = null
}
