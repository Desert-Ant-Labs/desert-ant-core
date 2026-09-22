package ai.desertant.tongue

/**
 * Process-wide Desert Ant configuration, for hosts where an environment
 * variable is not a natural fit (an Android app has no launch environment of
 * its own). Set once at launch, before the first Tongue call:
 *
 * ```kotlin
 * DesertAnt.apiKey = "pk_live_..."
 * ```
 *
 * Mirrors core's `DesertAnt.apiKey`. When unset, resolution falls back to the
 * `DAL_API_KEY` environment variable (or system property), and with neither
 * present attribution uses the app identity instead.
 */
public object DesertAnt {
    /** The publishable API key used for usage attribution. Null means unset. */
    @JvmStatic
    @Volatile
    public var apiKey: String? = null
}
