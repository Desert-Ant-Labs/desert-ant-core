package ai.desertant.schemer

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.AfterClass
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Calendar
import java.util.Date
import java.util.TimeZone
import kotlin.math.abs
import kotlin.time.Duration.Companion.minutes

/**
 * Instrumented tests over the real on-device path: JNI, the Swift core, and
 * LiteRT. Expected values are the reference goldens the Swift and Node suites
 * check (Tests/SchemerTests/Resources, packaged as test assets), in the golden's
 * `litert` column because that is what Android runs.
 *
 * The model is downloaded at the pinned revision, or adopted from a directory
 * on the device named by the `schemerModelDir` instrumentation argument, which
 * is how a revision is tested before it is published:
 *
 *     adb push <hub staging dir>/. /data/local/tmp/schemer
 *     ./gradlew :schemer:connectedDebugAndroidTest \
 *         -Pandroid.testInstrumentationRunnerArguments.schemerModelDir=/data/local/tmp/schemer
 */
@RunWith(AndroidJUnit4::class)
class SchemerTest {
    companion object {
        private lateinit var schemer: Schemer
        private val assets get() = InstrumentationRegistry.getInstrumentation().context.assets
        private val golden by lazy { JSONObject(assets.open("schemer_golden.json").bufferedReader().readText()) }

        // One extractor for the class: loading maps 90 MB of sidecars and
        // compiles three graphs, and nothing here depends on a fresh one.
        @BeforeClass @JvmStatic fun load() {
            val directory = InstrumentationRegistry.getArguments().getString("schemerModelDir")
            schemer = Schemer(ApplicationProvider.getApplicationContext(), directory)
            runBlocking { schemer.download() }
        }

        @AfterClass @JvmStatic fun close() { if (::schemer.isInitialized) schemer.close() }
    }

    private fun field(spec: JSONObject): Field {
        val name = spec.getString("name")
        val describe = spec.optString("describe").ifEmpty { null }
        val nullable = if (spec.has("nullable")) spec.getBoolean("nullable") else null
        spec.optJSONObject("items")?.optJSONArray("properties")?.let { props ->
            return Field.Objects(name, List(props.length()) { field(props.getJSONObject(it)) },
                describe, nullable)
        }
        return when (spec.getString("type")) {
            "number" -> Field.Number(name, describe, nullable,
                min = if (spec.has("min")) spec.getDouble("min") else null,
                max = if (spec.has("max")) spec.getDouble("max") else null,
                unit = spec.optString("unit").ifEmpty { null })
            "boolean" -> Field.Bool(name, describe, nullable)
            "datetime" -> Field.DateTime(name, describe, nullable)
            "array" -> Field.TextList(name, describe, nullable)
            "label" -> {
                val values = spec.getJSONArray("values")
                Field.Label(name, List(values.length()) { values.getString(it) }, describe, nullable)
            }
            else -> Field.Text(name, describe, nullable)
        }
    }

    /** Noon of that day where the device is, the day the SDK reads `now` as. */
    private fun date(ymd: String): Date {
        val (y, m, d) = ymd.split("-").map { it.toInt() }
        return Calendar.getInstance(TimeZone.getDefault()).apply {
            clear(); set(y, m - 1, d, 12, 0)
        }.time
    }

    /** The reference writes "" for an absent non-nullable string: the same answer as absent. */
    private fun same(got: Value, want: Any?): Boolean = when {
        want == null || want == JSONObject.NULL || want == "" ->
            got is Value.Absent || (got is Value.Text && got.value.isEmpty())
        got is Value.Objects && want is JSONArray ->
            got.items.size == want.length() && got.items.indices.all { i ->
                val w = want.getJSONObject(i)
                w.keys().asSequence().toSet() == got.items[i].keys &&
                    got.items[i].all { (k, v) -> same(v, w.get(k)) }
            }
        got is Value.Number && want is Number -> abs(got.value - want.toDouble()) < 1e-6
        got is Value.Bool -> want == got.value
        got is Value.TextList && want is JSONArray ->
            got.values == List(want.length()) { want.getString(it) }
        else -> got.orNull() == want
    }

    private val cases: List<JSONObject>
        get() = golden.getJSONArray("cases").let { a -> List(a.length()) { a.getJSONObject(it) } }

    private fun schemaOf(c: JSONObject): List<Field> =
        c.getJSONArray("schema").let { a -> List(a.length()) { field(a.getJSONObject(it)) } }

    /**
     * The golden was made on an M1's NEON kernels, and an arm64 device matches
     * it on every field (2% allowed). On an x86_64 emulator the dynamic-range
     * int8 kernels differ and round a field on a decision boundary the other
     * way (8 of 115 measured), so 10% there. Each is logged. The Swift suite's
     * `Golden.allowedDisagreements` says the same.
     */
    @Test fun everyGoldenCaseMatchesTheReference() = runTest(timeout = 30.minutes) {
        var fields = 0
        val differ = mutableListOf<String>()
        for (c in cases) {
            val schema = schemaOf(c)
            val out = schemer.extract(c.getString("text"), schema, date(c.getString("now")))
            assertEquals("${c.getString("id")}: schema order", schema.map { it.name }, out.fields)
            val want = c.getJSONObject("expected").getJSONObject("litert")
            for (f in schema) {
                val got = out[f.name]
                if (!same(got, want.opt(f.name))) {
                    differ += "${c.getString("id")}.${f.name}: got $got, reference ${want.opt(f.name)}"
                }
                fields += 1
            }
        }
        assertTrue(fields > 100)
        val slack = if (android.os.Build.SUPPORTED_ABIS.first().startsWith("x86")) 0.10 else 0.02
        differ.forEach { android.util.Log.w("SchemerTest", "differs from the reference: $it") }
        assertTrue("${differ.size} of $fields fields differ:\n${differ.joinToString("\n")}",
            differ.size <= kotlin.math.ceil(fields * slack).toInt())
    }

    /** The encoder writes the bytes the JS encoder wrote and the Swift reader decodes. */
    @Test fun encoderMatchesTheCommittedWireBytes() {
        val schema = listOf(
            Field.Text("merchant", describe = "the shop or vendor", nullable = true),
            Field.Number("amount", describe = "total paid", min = 0.0, max = 10000.0, unit = "currency"),
            Field.Bool("reimbursable"),
            Field.Label("category", listOf("food", "travel", "office")),
            Field.DateTime("when"),
            Field.TextList("attendees", nullable = false),
            Field.Number("guests"),
            Field.Objects("lines", listOf(
                Field.Text("item", describe = "product"),
                Field.Number("quantity", min = 1.0),
                Field.Label("size", listOf("S", "L"), nullable = false),
            ), describe = "order lines"),
        )
        val want = assets.open("schemer_wire.input").use { it.readBytes() }
        assertArrayEquals(want, encodeInput("Coffee at Blue Bottle, \$18.50", schema))
    }

    @Test fun nowPinsRelativeDates() = runTest(timeout = 5.minutes) {
        val schema = listOf(Field.DateTime("when", describe = "when to be reminded"))
        val text = "Remind me to call the dentist tomorrow at 9:30."
        assertEquals(Value.DateTime("2026-03-11T09:30"), schemer.extract(text, schema, date("2026-03-10"))["when"])
        assertEquals(Value.DateTime("2027-01-01T09:30"), schemer.extract(text, schema, date("2026-12-31"))["when"])
    }

    @Test fun concurrentCallsAgree() = runTest(timeout = 10.minutes) {
        val few = cases.filter { it.getString("text").length < 200 }.take(4)
        val serial = few.map { schemer.extract(it.getString("text"), schemaOf(it), date(it.getString("now"))).toAnyMap() }
        val parallel = few.map { c ->
            async { schemer.extract(c.getString("text"), schemaOf(c), date(c.getString("now"))).toAnyMap() }
        }.awaitAll()
        assertEquals(serial, parallel)
    }

    @Test fun reportsTextPastTheWindow() = runTest(timeout = 10.minutes) {
        val schema = listOf(Field.Number("total", nullable = true))
        val long = "The quick brown fox jumps over the lazy dog. ".repeat(400) + "The invoice total is \$42."
        assertTrue(schemer.extract(long, schema).truncated)
        assertTrue(!schemer.extract("The invoice total is \$42.", schema).truncated)
    }

    @Test fun emptySchemaRunsNothing() = runTest {
        assertTrue(schemer.extract("anything", emptyList()).fields.isEmpty())
    }

    @Test fun rejectsWhatTheRuntimeCannotHonor() {
        fun rejects(schema: List<Field>) {
            val error = runCatching { runBlocking { schemer.extract("x", schema) } }.exceptionOrNull()
            assertTrue("$schema: $error", error is SchemerException)
            // The same check with no model, for a caller that validates first.
            val early = runCatching { Schemer.validate(schema) }.exceptionOrNull()
            assertTrue("$schema: $early", early is SchemerException)
        }
        Schemer.validate(listOf(Field.Text("a"), Field.Number("n", min = 0.0, max = 5.0)))
        rejects(listOf(Field.Label("a", emptyList())))
        rejects(listOf(Field.Label("a", List(MAX_LABEL_VALUES + 1) { "v$it" })))
        rejects(listOf(Field.Text("a"), Field.Number("a")))
        rejects(listOf(Field.Text("")))
        rejects(listOf(Field.Number("a", max = Double.NaN)))
        rejects(listOf(Field.Number("a", min = 5.0, max = 1.0)))
    }

    @Test fun isDownloadedAfterDownload() {
        assertTrue(schemer.isDownloaded())
    }
}
