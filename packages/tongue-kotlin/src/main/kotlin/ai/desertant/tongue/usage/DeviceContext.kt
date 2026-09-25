package ai.desertant.tongue.usage

import java.text.BreakIterator
import java.util.Locale

/**
 * The per-event `context`: coarse facts about the app and the device it runs on.
 * A port of desert-ant-core's `Sources/Usage/DeviceContext.swift`, which sets the
 * rules; core reads Android's facts through its Kotlin host bridge, and this port
 * reads the same ones reflectively (see Storage.kt for why).
 *
 *   Android   appVersion, osName, osVersion, deviceModel, formFactor, locale
 *   JVM       osName, a major-only osVersion (a JVM is a `server`)
 *
 * A server, and any client whose device id the host supplied, sends only osName,
 * a major-only osVersion and appVersion: that device is not this process's to
 * describe. Nothing that identifies the device: no serial, ANDROID_ID or build
 * fingerprint. `DAL_APP_VERSION` overrides the app version, and
 * `DesertAnt.sendsDeviceContext = false` or `DAL_USAGE_CONTEXT_DISABLED` sends
 * usage without any context.
 */

/** The keys the ingest accepts in an event's `context`. Anything else is dropped. */
internal val CONTEXT_KEYS: Set<String> = setOf(
    "appVersion", "osName", "osVersion", "deviceModel",
    "browserName", "browserVersion", "formFactor", "locale",
)

/** The values the ingest accepts for `formFactor`. */
internal val FORM_FACTORS: Set<String> = setOf("desktop", "mobile", "tablet")

/** Per-value cap, in UTF-8 bytes. Core's, so every port reports the same values. */
internal const val MAX_CONTEXT_VALUE_BYTES: Int = 64

/**
 * Cap on the encoded context. The ingest rejects the whole batch at 4096 bytes,
 * so this stays well under it; over it, the event goes without context.
 */
internal const val MAX_CONTEXT_BYTES: Int = 1024

/** Facts about this host, read once per client. */
internal data class DeviceFacts(
    val appVersion: String? = null,
    val osName: String? = null,
    /** major.minor where the platform has one. */
    val osVersion: String? = null,
    val deviceModel: String? = null,
    val formFactor: String? = null,
    /** language-region, e.g. "pt-BR". */
    val locale: String? = null,
) {
    /** The context sent for this host. `minimal` is the server set. */
    fun fields(minimal: Boolean, appVersionOverride: String? = null): Map<String, String> {
        val out = linkedMapOf<String, String?>()
        out["appVersion"] = appVersionOverride ?: appVersion
        out["osName"] = osName
        if (minimal) {
            out["osVersion"] = osVersion?.substringBefore('.')
        } else {
            out["osVersion"] = osVersion
            out["deviceModel"] = deviceModel
            out["formFactor"] = formFactor
            out["locale"] = locale
        }
        return out.filterValues { it != null }.mapValues { it.value!! }
    }
}

/**
 * The default `context` provider [makeClient] wires. The facts are read once;
 * the opt-out and the appVersion override are read per event, so a host that
 * sets either after the client is built is still honoured.
 */
internal fun defaultContextProvider(
    platform: String,
    deviceIdSupplied: Boolean,
    facts: DeviceFacts,
): () -> Map<String, String>? {
    val minimal = platform == "server" || deviceIdSupplied
    return { facts.fields(minimal, hostProvidedAppVersion()) }
}

/** `DAL_APP_VERSION`, the environment then the system property, or null. */
internal fun hostProvidedAppVersion(): String? = setting("DAL_APP_VERSION")

/**
 * Whether the event `context` is switched off: `DesertAnt.sendsDeviceContext`
 * set to false in code, or `DAL_USAGE_CONTEXT_DISABLED` under `flagIsSet` in the
 * environment or as the same-named system property. Either one opts out.
 * Usage itself still reports; only the context goes.
 */
internal fun deviceContextDisabled(): Boolean =
    !ai.desertant.tongue.DesertAnt.sendsDeviceContext ||
        flagIsSet(readEnvironment("DAL_USAGE_CONTEXT_DISABLED")) ||
        flagIsSet(System.getProperty("DAL_USAGE_CONTEXT_DISABLED"))

/**
 * The truthiness rule every port's opt-out flags share, usage and context alike:
 * set, and not "", "0" or "false". This port reads strings only (the environment
 * and system properties), so a number arrives as its text: "1" is set and "0"
 * is not, as the JS ports' number rule has it. It fails closed.
 */
internal fun flagIsSet(value: String?): Boolean =
    value != null && value != "" && value != "0" && value != "false"

/**
 * `context` reduced to what the ingest will accept without rejecting the batch:
 * allowlisted keys, printable values of at most [MAX_CONTEXT_VALUE_BYTES], a
 * known formFactor, and at most [MAX_CONTEXT_BYTES] encoded. Null when nothing
 * is left or the whole is still too big.
 */
internal fun sanitizeContext(context: Map<String, String>?): Map<String, String>? {
    if (context == null) return null
    val out = linkedMapOf<String, String>()
    for ((key, raw) in context) {
        if (key !in CONTEXT_KEYS) continue
        val value = printableValue(raw)
        if (value.isEmpty()) continue
        if (key == "formFactor" && value !in FORM_FACTORS) continue
        out[key] = value
    }
    if (out.isEmpty()) return null
    val encoded = buildString { appendContext(out) }
    return if (encoded.toByteArray(Charsets.UTF_8).size <= MAX_CONTEXT_BYTES) out else null
}

/**
 * `raw` without control or invisible formatting characters, trimmed, and cut to
 * [MAX_CONTEXT_VALUE_BYTES] without splitting a character (a grapheme, as core
 * cuts on Swift's `Character`).
 */
internal fun printableValue(raw: String): String {
    val kept = buildString {
        var index = 0
        while (index < raw.length) {
            val code = raw.codePointAt(index)
            if (isPrintable(code)) appendCodePoint(code)
            index += Character.charCount(code)
        }
    }.trim()
    val out = StringBuilder()
    var bytes = 0
    val breaks = BreakIterator.getCharacterInstance(Locale.ROOT)
    breaks.setText(kept)
    var start = breaks.first()
    var end = breaks.next()
    while (end != BreakIterator.DONE) {
        val character = kept.substring(start, end)
        bytes += character.toByteArray(Charsets.UTF_8).size
        if (bytes > MAX_CONTEXT_VALUE_BYTES) break
        out.append(character)
        start = end
        end = breaks.next()
    }
    return out.toString().trim()
}

private fun isPrintable(code: Int): Boolean = when (code) {
    in 0 until 0x20, in 0x7F..0x9F -> false // C0, DEL, C1
    in 0xD800..0xDFFF -> false // a lone surrogate, which a strict JSON reader rejects
    in 0x200B..0x200F, in 0x2028..0x202E, in 0x2060..0x206F -> false // zero-width, separators, bidi
    0xAD, 0x180E, in 0xFE00..0xFE0F, 0xFEFF, in 0xFFF9..0xFFFB, in 0xE0000..0xE007F -> false
    else -> true
}

/** "8.1.0" -> "8.1", "6.8.0-45-generic" -> "6.8". Null when it does not start with a number. */
internal fun majorMinor(version: String): String? {
    val numeric = version.trim().takeWhile { it.isDigit() || it == '.' }
    return numeric.split('.').filter { it.isNotEmpty() }.take(2).joinToString(".").ifEmpty { null }
}

/** Google's own tablet line: a smallest width of 600dp or more. 0 is undefined. */
internal fun formFactor(smallestWidthDp: Int): String? = when {
    smallestWidthDp <= 0 -> null
    smallestWidthDp >= 600 -> "tablet"
    else -> "mobile"
}

/**
 * Language and region only: "zh-Hant-TW" -> "zh-TW", "fr" -> "fr". Through the
 * language tag, so Hebrew reads "he" rather than the legacy "iw".
 */
internal fun languageRegion(locale: Locale): String? {
    val language = locale.toLanguageTag().substringBefore('-')
    if (language.isEmpty() || language == "und") return null
    return if (locale.country.isEmpty()) language else "$language-${locale.country}"
}

/**
 * The facts from each reader. A reader that throws, or returns nothing usable,
 * leaves its fact out rather than failing the model's construction.
 */
internal fun androidFacts(
    appVersion: () -> String?,
    osRelease: () -> String?,
    model: () -> String?,
    smallestWidthDp: () -> Int?,
    locale: () -> Locale?,
): DeviceFacts = DeviceFacts(
    appVersion = attempt(appVersion)?.trim()?.ifEmpty { null },
    osName = "Android",
    osVersion = attempt(osRelease)?.let(::majorMinor),
    deviceModel = attempt(model)?.trim()?.ifEmpty { null },
    formFactor = attempt(smallestWidthDp)?.let(::formFactor),
    locale = attempt(locale)?.let(::languageRegion),
)

private fun <T> attempt(read: () -> T?): T? = try { read() } catch (_: Throwable) { null }

/**
 * This host's facts: Android's through reflection when it is Android (with or
 * without a Context), otherwise the JVM's OS name and version.
 */
internal fun detectDeviceFacts(context: Any?): DeviceFacts =
    if (isAndroid()) reflectedAndroidFacts(context) else jvmFacts()

/**
 * Android's facts, reached reflectively so this file compiles and runs on a bare
 * JVM. Methods are looked up on the public SDK classes rather than the runtime
 * class, which may be a hidden one reflection cannot call. Without a Context
 * there is no app version, and the form factor comes from the system resources.
 */
private fun reflectedAndroidFacts(context: Any?): DeviceFacts {
    val contextClass = runCatching { Class.forName("android.content.Context") }.getOrNull()
    val appContext = context?.takeIf { contextClass?.isInstance(it) == true }
    // The application's configuration, not an Activity's: a tablet Activity in
    // split screen can report under 600dp, and the facts last the client.
    val application = appContext?.let { runCatching { contextClass!!.getMethod("getApplicationContext").invoke(it) }.getOrNull() }
        ?: appContext
    return androidFacts(
        appVersion = {
            appContext?.let {
                val packageManager = contextClass!!.getMethod("getPackageManager").invoke(it)
                val packageName = contextClass.getMethod("getPackageName").invoke(it)
                val info = Class.forName("android.content.pm.PackageManager")
                    .getMethod("getPackageInfo", String::class.java, Int::class.javaPrimitiveType)
                    .invoke(packageManager, packageName, 0)
                Class.forName("android.content.pm.PackageInfo").getField("versionName").get(info) as String?
            }
        },
        osRelease = { Class.forName("android.os.Build\$VERSION").getField("RELEASE").get(null) as String? },
        model = { Class.forName("android.os.Build").getField("MODEL").get(null) as String? },
        smallestWidthDp = {
            val resourcesClass = Class.forName("android.content.res.Resources")
            val resources = application?.let { contextClass!!.getMethod("getResources").invoke(it) }
                ?: resourcesClass.getMethod("getSystem").invoke(null)
            val configuration = resourcesClass.getMethod("getConfiguration").invoke(resources)
            Class.forName("android.content.res.Configuration").getField("smallestScreenWidthDp").getInt(configuration)
        },
        locale = {
            val localeList = Class.forName("android.os.LocaleList")
            val defaults = localeList.getMethod("getDefault").invoke(null)
            localeList.getMethod("get", Int::class.javaPrimitiveType).invoke(defaults, 0) as Locale?
        },
    )
}

/** A JVM is a `server`, which sends the OS and a major-only version. */
private fun jvmFacts(): DeviceFacts {
    val name = System.getProperty("os.name").orEmpty()
    val osName = when {
        name.startsWith("Mac") -> "macOS"
        name.startsWith("Windows") -> "Windows"
        name.startsWith("Linux") -> "Linux"
        else -> name.ifEmpty { null }
    }
    return DeviceFacts(osName = osName, osVersion = System.getProperty("os.version")?.let(::majorMinor))
}
