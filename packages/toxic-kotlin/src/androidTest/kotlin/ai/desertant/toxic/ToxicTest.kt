package ai.desertant.toxic

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs

/**
 * Instrumented tests over the real on-device path: JNI, the Swift core, the
 * tokenizer and LiteRT. Expected scores are the reference goldens the Swift and
 * Node suites check (Tests/ToxicTests/Resources, packaged as test assets). The
 * model is adopted from the test assets when a local export was packaged
 * (TOXIC_MODEL_DIR at build time), else downloaded at the pinned revision.
 */
@RunWith(AndroidJUnit4::class)
class ToxicTest {
    private lateinit var toxic: Toxic
    private val assets = InstrumentationRegistry.getInstrumentation().context.assets
    private val golden by lazy { JSONObject(assets.open("toxic_golden.json").bufferedReader().readText()) }

    /** The published artifact against the torch float32 reference: the 4-bit table and the dynamic int8 layers land
     *  within 0.1 on the golden texts (0.081 at v0.2.2, on a target head under its threshold). */
    private val tolerance = 0.1

    @Before fun setUp() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val directory = if ("litert-mixed" in assets.list("").orEmpty()) {
            File(context.cacheDir, "toxic-local").apply {
                mkdirs()
                for (name in listOf("litert-mixed/toxic.tflite", "litert-mixed/toxic_meta.json", "toxic_tokenizer.bin")) {
                    val target = File(this, name)
                    target.parentFile?.mkdirs()
                    assets.open(name).use { src -> target.outputStream().use { src.copyTo(it) } }
                }
            }.path
        } else null
        toxic = Toxic(context, directory)
        runBlocking { toxic.download() }
    }

    @After fun tearDown() { if (::toxic.isInitialized) toxic.close() }

    private fun singleWindow(k: Int): Boolean {
        val ids = golden.getJSONArray("input_ids").getJSONArray(k)
        return (0 until ids.length()).count { ids.getInt(it) != 0 } < ids.length()
    }

    @Test fun goldenTextsMatchTheReference() = runTest {
        val texts = golden.getJSONArray("texts")
        val heads = golden.getJSONArray("heads")
        val reference = golden.getJSONArray("reference")
        for (k in 0 until texts.length()) {
            val result = toxic.analyze(texts.getString(k))
            for (h in 0 until heads.length()) {
                val label = Label.byId(heads.getString(h))!!
                val want = reference.getJSONArray(k).getDouble(h)
                val got = result.score(label)
                if (singleWindow(k)) assertTrue("text $k $label: got $got, want $want", abs(got - want) < tolerance)
                else assertTrue("text $k $label: got $got, want at least $want", got >= want - tolerance)
            }
        }
    }

    @Test fun hatefulTextIsFlagged() = runTest {
        val hateful = toxic.analyze(golden.getJSONArray("texts").getString(4))
        assertTrue(hateful.isToxic)
        assertTrue(Label.HATEFUL in hateful.flagged)
        val kind = toxic.analyze(golden.getJSONArray("texts").getString(0))
        assertFalse(kind.isToxic)
        assertEquals(Label.entries.toSet(), kind.scores.keys)
    }

    @Test fun thresholdsReplaceTheDefaults() = runTest {
        val defaults = toxic.analyze("hello")
        val low = toxic.analyze("hello", Options(thresholds = mapOf(Label.HATEFUL to 0.0)))
        assertTrue(Label.HATEFUL in low.flagged)
        assertEquals(0.0, low.thresholds.getValue(Label.HATEFUL), 0.0)
        assertEquals(defaults.thresholds.getValue(Label.ABUSIVE), low.thresholds.getValue(Label.ABUSIVE), 0.0)
        assertEquals(defaults.scores, low.scores)
    }

    @Test fun rejectsNonFiniteThresholds() {
        val error = runCatching { runBlocking { toxic.analyze("x", Options(thresholds = mapOf(Label.HATEFUL to Double.NaN))) } }.exceptionOrNull()
        assertTrue(error is IllegalArgumentException)
    }
}
