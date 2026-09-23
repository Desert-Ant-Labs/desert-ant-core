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

    /**
     * Whether usage events carry the device context (OS, model, locale and the
     * like; see usage/DeviceContext.kt). `true` by default. Setting it to
     * `false` sends usage without context, the in-code form of the
     * `DAL_USAGE_CONTEXT_DISABLED` flag, as core's `DesertAnt.sendsDeviceContext`
     * is. Read per event, so it applies from the next send on.
     */
    @JvmStatic
    @Volatile
    public var sendsDeviceContext: Boolean = true
}
