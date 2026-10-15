package ai.desertant.tongue

public object DesertAnt {
    @Deprecated("Has no effect: Tongue sends no requests.")
    @JvmStatic
    @Volatile
    public var apiKey: String? = null

    @Deprecated("Has no effect: Tongue sends no requests.")
    @JvmStatic
    @Volatile
    public var sendsDeviceContext: Boolean = true
}
