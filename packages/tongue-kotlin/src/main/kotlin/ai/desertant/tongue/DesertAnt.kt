package ai.desertant.tongue

import ai.desertant.tongue.license.trimmedKey

/**
 * Process-wide Desert Ant configuration. Call once at launch, before the first model call:
 *
 * ```kotlin
 * DesertAnt.configure(apiKey = "dal_...")
 * ```
 */
public object DesertAnt {
    @Volatile
    private var configuredApiKey: String? = null

    @Volatile
    private var configuredDeviceIdSecret: String? = null

    internal val currentApiKey: String? get() = configuredApiKey

    internal val currentDeviceIdSecret: String? get() = trimmedKey(configuredDeviceIdSecret)

    /** Sets the API key that license requests send. */
    @JvmStatic
    public fun configure(apiKey: String) {
        configuredApiKey = apiKey
    }

    /**
     * Sets the API key and the device id secret, for a process that serves many devices, such
     * as a server. Do not use it in an app that ships to users: a secret in an app is public.
     *
     * The secret is 32 or more random bytes as text, kept on the server and never changed.
     * Tongue uses it to turn each call's device id into the install id it sends. The device id
     * never leaves the server, and only the holder of the secret can link the two.
     */
    @JvmStatic
    @Synchronized
    public fun configure(apiKey: String, deviceIdSecret: String) {
        if (trimmedKey(deviceIdSecret) == null) {
            java.util.logging.Logger.getLogger("ai.desertant.tongue")
                .warning("DesertAnt.configure was given a blank deviceIdSecret, so device ids are hashed without a secret.")
        }
        configuredApiKey = apiKey
        configuredDeviceIdSecret = deviceIdSecret
    }
}
