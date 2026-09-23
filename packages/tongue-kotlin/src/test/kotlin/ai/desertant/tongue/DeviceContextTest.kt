package ai.desertant.tongue

import ai.desertant.tongue.usage.ClientDeps
import ai.desertant.tongue.usage.DeviceFacts
import ai.desertant.tongue.usage.IngestBody
import ai.desertant.tongue.usage.InMemoryStorage
import ai.desertant.tongue.usage.MAX_CONTEXT_VALUE_BYTES
import ai.desertant.tongue.usage.UsageClient
import ai.desertant.tongue.usage.UsageState
import ai.desertant.tongue.usage.androidFacts
import ai.desertant.tongue.usage.buildBody
import ai.desertant.tongue.usage.defaultContextProvider
import ai.desertant.tongue.usage.formFactor
import ai.desertant.tongue.usage.languageRegion
import ai.desertant.tongue.usage.majorMinor
import ai.desertant.tongue.usage.makeClient
import ai.desertant.tongue.usage.readEnvironment
import ai.desertant.tongue.usage.sanitizeContext
import java.util.Locale
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The usage `context`, which core sets the rules for (Sources/Usage/DeviceContext.swift).
 * Kotlin-only on purpose: the shared usage_vectors.json is the turnstile contract
 * the JavaScript port replays byte for byte, and each port gathers its context
 * from a different host, so none of it goes there.
 *
 * `readEnvironment`, the system properties and `DesertAnt` are process-wide; see
 * UsageKillSwitchTest for why that is safe here.
 */
class DeviceContextTest {
    private var previousEnvironment: (String) -> String? = readEnvironment
    private val properties = listOf("DAL_APP_VERSION", "DAL_USAGE_CONTEXT_DISABLED", "DAL_DEVICE_ID")
    private val previousProperties = mutableMapOf<String, String?>()

    @BeforeTest fun isolate() {
        previousEnvironment = readEnvironment
        readEnvironment = { null }
        for (name in properties) { previousProperties[name] = System.getProperty(name); System.clearProperty(name) }
        DesertAnt.sendsDeviceContext = true
    }

    @AfterTest fun restore() {
        readEnvironment = previousEnvironment
        for ((name, value) in previousProperties) {
            if (value == null) System.clearProperty(name) else System.setProperty(name, value)
        }
        DesertAnt.sendsDeviceContext = true
    }

    private val phone = DeviceFacts(
        appVersion = "2.4.1", osName = "Android", osVersion = "14",
        deviceModel = "Pixel 8 Pro", formFactor = "mobile", locale = "pt-BR",
    )

    @Test fun androidFactsComeFromEachReader() {
        val facts = androidFacts(
            appVersion = { "2.4.1" },
            osRelease = { "8.1.0" },
            model = { "Pixel 8 Pro" },
            smallestWidthDp = { 800 },
            locale = { Locale.forLanguageTag("zh-Hant-TW") },
        )
        assertEquals(
            DeviceFacts("2.4.1", "Android", "8.1", "Pixel 8 Pro", "tablet", "zh-TW"),
            facts,
        )
    }

    /** A reader that throws (a missing package, an OEM's broken locale list) or
     *  reads as nothing leaves its fact out, and the rest still go. */
    @Test fun aFactThatFailsIsLeftOut() {
        val facts = androidFacts(
            appVersion = { throw ReflectiveOperationException("NameNotFoundException") },
            osRelease = { null },
            model = { " " },
            smallestWidthDp = { throw NoSuchFieldError("smallestScreenWidthDp") },
            locale = { Locale.ROOT },
        )
        assertEquals(DeviceFacts(osName = "Android"), facts)
    }

    @Test fun theHelpersMatchCore() {
        assertEquals("14", majorMinor("14"))
        assertEquals("6.8", majorMinor("6.8.0-45-generic"))
        assertNull(majorMinor("Baklava"))
        assertEquals("mobile", formFactor(599))
        assertEquals("tablet", formFactor(600))
        assertNull(formFactor(0))
        assertEquals("pt-BR", languageRegion(Locale("pt", "BR")))
        assertEquals("es-419", languageRegion(Locale.forLanguageTag("es-419")))
        assertEquals("he", languageRegion(Locale.forLanguageTag("he")))
        assertEquals("fr", languageRegion(Locale.FRENCH))
        assertNull(languageRegion(Locale.ROOT))
    }

    @Test fun anAndroidDeviceSendsTheFullSet() {
        val context = defaultContextProvider("android", deviceIdSupplied = false, facts = phone)()
        assertEquals(
            mapOf(
                "appVersion" to "2.4.1", "osName" to "Android", "osVersion" to "14",
                "deviceModel" to "Pixel 8 Pro", "formFactor" to "mobile", "locale" to "pt-BR",
            ),
            context,
        )
    }

    /** A supplied device id is a tenant's device, so the host's model and
     *  locale say nothing about it; a server is the same set. */
    @Test fun aSuppliedDeviceIdOrAServerSendsTheMinimalSet() {
        val minimal = mapOf("appVersion" to "2.4.1", "osName" to "Android", "osVersion" to "14")
        assertEquals(minimal, defaultContextProvider("android", deviceIdSupplied = true, facts = phone)())
        assertEquals(minimal, defaultContextProvider("server", deviceIdSupplied = false, facts = phone)())
        assertEquals(
            "8",
            defaultContextProvider("server", false, DeviceFacts(osName = "Linux", osVersion = "8.1"))()!!["osVersion"],
        )
    }

    @Test fun anAppVersionOverrideWinsPerEvent() {
        val provider = defaultContextProvider("android", deviceIdSupplied = false, facts = phone)
        System.setProperty("DAL_APP_VERSION", "9.9")
        assertEquals("9.9", provider()!!["appVersion"])
    }

    @Test fun sanitizingKeepsTheAllowlistAndTheCaps() {
        assertEquals(
            mapOf("osName" to "Android", "locale" to "pt-BR"),
            sanitizeContext(mapOf("osName" to "Android", "serial" to "R58M123", "locale" to "pt-BR", "formFactor" to "phablet")),
        )
        val long = sanitizeContext(mapOf("deviceModel" to "M".repeat(300)))!!["deviceModel"]!!
        assertEquals(MAX_CONTEXT_VALUE_BYTES, long.length)
        // A cut never splits a character: 17 four-byte emoji are 68 bytes.
        val emoji = sanitizeContext(mapOf("deviceModel" to "\uD83D\uDE00".repeat(17)))!!["deviceModel"]!!
        assertEquals(16 * 2, emoji.length)
        assertEquals("Pixel 8", sanitizeContext(mapOf("deviceModel" to " Pixel\u200B 8\n "))!!["deviceModel"])
        assertNull(sanitizeContext(mapOf("osName" to "\u0000\u200B")))
        assertNull(sanitizeContext(null))
    }

    @Test fun theJvmClientSendsTheServerSet() {
        val body = loadOnce()
        val context = assertNotNull(body.events.single().context, "a JVM client sent no context")
        assertEquals(setOf("osName", "osVersion"), context.keys)
        assertTrue(!context.getValue("osVersion").contains('.'), "a server's version is major only: $context")
        assertTrue(buildBody(body).contains("\"context\":{\"osName\":"), buildBody(body))
    }

    @Test fun theInCodeOptOutSendsUsageWithoutContext() {
        DesertAnt.sendsDeviceContext = false
        val event = loadOnce().events.single()
        assertNull(event.context)
        assertEquals(1, event.callCount, "the opt-out dropped the usage too")
    }

    @Test fun theFlagOptOutSendsUsageWithoutContext() {
        System.setProperty("DAL_USAGE_CONTEXT_DISABLED", "1")
        assertNull(loadOnce().events.single().context)
        System.setProperty("DAL_USAGE_CONTEXT_DISABLED", "false")
        assertNotNull(loadOnce().events.single().context, "\"false\" is not an opt-out")
        readEnvironment = { name -> if (name == "DAL_USAGE_CONTEXT_DISABLED") "true" else null }
        assertNull(loadOnce().events.single().context)
    }

    @Test fun anExplicitContextObeysTheOptOutAndTheCaps() {
        val sent = mutableListOf<IngestBody>()
        val client = client(sent)
        client.load(mapOf("osName" to "Android", "deviceName" to "Ana's phone"))
        assertEquals(mapOf("osName" to "Android"), sent.single().events.single().context)

        DesertAnt.sendsDeviceContext = false
        client.load(mapOf("osName" to "Android"))
        assertNull(sent.last().events.single().context)
    }

    /** The turnstile is queued on start and sent on the debounce; an opt-out set
     *  in between still keeps its context off the wire. */
    @Test fun anOptOutSetBeforeTheFlushDropsTheQueuedContext() {
        val sent = mutableListOf<IngestBody>()
        val client = client(sent)
        client.start()
        DesertAnt.sendsDeviceContext = false
        client.flush()
        assertNull(sent.single().events.single().context)
    }

    @Test fun aProviderThatThrowsCostsTheContextNotTheEvent() {
        val sent = mutableListOf<IngestBody>()
        client(sent) { throw IllegalStateException("boom") }.load()
        assertEquals(1, sent.size)
        assertNull(sent.single().events.single().context)
    }

    private fun loadOnce(): IngestBody {
        val sent = mutableListOf<IngestBody>()
        val client = makeClient(sdkVersion = "9.9.9", storage = InMemoryStorage(), send = { sent.add(it); null })
        client.recordCall()
        client.load()
        return sent.single()
    }

    private fun client(
        sent: MutableList<IngestBody>,
        context: () -> Map<String, String>? = { mapOf("osName" to "Android") },
    ): UsageClient {
        var state = UsageState()
        return UsageClient(
            ClientDeps(
                deviceId = "device-under-test",
                platform = "android",
                sdkVersion = "9.9.9",
                context = context,
                now = { 1_700_000_000_000L },
                loadState = { state },
                saveState = { state = it },
                send = { sent.add(it); null },
            ),
        )
    }
}
