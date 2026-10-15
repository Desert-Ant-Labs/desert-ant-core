package ai.desertant.eye

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs

/**
 * Instrumented tests over the real on-device path: JNI, the Swift core, and
 * LiteRT running each function as a signature of eye.tflite. The expected
 * analysis is the reference the Swift and Node suites check
 * (Tests/EyeTests/Resources, packaged as test assets). The model is adopted from
 * the test assets when a local export was packaged (EYE_MODEL_DIR at build
 * time), else downloaded at the pinned revision.
 */
@RunWith(AndroidJUnit4::class)
class EyeTest {
    private lateinit var eye: Eye
    private val assets = InstrumentationRegistry.getInstrumentation().context.assets
    private val golden by lazy { JSONObject(assets.open("eye_golden.json").bufferedReader().readText()).getJSONObject("fixture") }

    @Before fun setUp() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val directory = if ("eye.tflite" in assets.list("").orEmpty()) {
            File(context.cacheDir, "eye-local").apply {
                mkdirs()
                for (name in listOf("eye.tflite", "eye_meta.json")) {
                    assets.open(name).use { src -> File(this, name).outputStream().use { src.copyTo(it) } }
                }
            }.path
        } else null
        eye = Eye(context, directory)
        runBlocking { eye.download() }
    }

    @After fun tearDown() { if (::eye.isInitialized) eye.close() }

    private fun fixture(): ByteArray {
        val gray = assets.open("eye_fixture.gray").readBytes()
        val rgb = ByteArray(gray.size * 3)
        for (i in gray.indices) { rgb[i * 3] = gray[i]; rgb[i * 3 + 1] = gray[i]; rgb[i * 3 + 2] = gray[i] }
        return rgb
    }

    private fun assertClose(got: Map<String, Double>, want: JSONObject, tolerance: Double, what: String) {
        for (key in want.keys()) {
            val value = got[key] ?: error("$what: no $key")
            assertTrue("$what.$key: got $value, want ${want.getDouble(key)}", abs(value - want.getDouble(key)) < tolerance)
        }
    }

    @Test fun fixtureMatchesReference() = runTest {
        val want = golden.getJSONObject("analysis")
        val analysis = eye.analyze(fixture(), golden.getInt("width"), golden.getInt("height"))
        val details = analysis.details!!

        // Tags: the same decision at 0.5 and 0.9 unless either side is within 0.1 of the cutoff.
        val wantTags = want.getJSONObject("tags").getJSONObject("tags")
        assertEquals(wantTags.keys().asSequence().toSet(), analysis.confidences.keys.map { it.id }.toSet())
        for (key in wantTags.keys()) {
            val g = analysis.confidence(Tag(key))!!
            val w = wantTags.getDouble(key)
            for (cut in listOf(0.5, 0.9)) {
                assertTrue("tag $key: $g vs $w", (g >= cut) == (w >= cut) || abs(g - cut) <= 0.1 || abs(w - cut) <= 0.1)
            }
        }
        val computed = analysis.confidences.keys + analysis.faces!!.flatMap { it.confidences.keys }
        assertEquals("every tag has a constant", Tags.ALL.toSet(), computed.toSet())
        val restored = Analysis.fromJson(analysis.toJson())
        assertEquals(analysis.confidences, restored.confidences)
        assertNull(restored.details)
        assertEquals(listOf(listOf(0, 1)), Eye.duplicates(listOf(analysis, restored)))

        val photo = details.photo!!
        val p = want.getJSONObject("photo")
        val embedding = p.getJSONArray("embedding")
        val dot = photo.embedding.indices.sumOf { photo.embedding[it] * embedding.getDouble(it) }
        assertTrue("embedding cosine $dot", dot > 0.98)
        for ((name, got) in listOf("type" to photo.type, "reject" to photo.reject, "scenes" to photo.scenes,
            "blur" to photo.blur, "peak" to photo.peak)) {
            assertClose(got, p.getJSONObject(name), 0.08, name)
        }
        assertTrue(abs(photo.aesthetic - p.getDouble("aesthetic")) < 0.08)
        assertTrue(abs(photo.keeper - p.getDouble("keeper")) < 0.08)

        val layout = details.layout!!
        assertClose(layout.shot, want.getJSONObject("layout").getJSONObject("shot"), 0.08, "shot")
        assertEquals(64 * 64, layout.attention.values.size)
        assertEquals(want.getJSONObject("layout").getJSONArray("crops").length(), layout.crops.size)

        val faces = details.faces!!
        assertEquals(want.getJSONArray("faces").length(), faces.size)
        assertTrue(faces.all { it.landmarks.size == 5 && it.isFace >= 0.5 })

        val sharpness = details.sharpness!!
        assertTrue(abs(sharpness.score - want.getJSONObject("sharpness").getDouble("score")) < 0.05)
    }

    @Test fun partsLimitTheWork() = runTest {
        val analysis = eye.analyze(fixture(), golden.getInt("width"), golden.getInt("height"), Options(parts = setOf(Part.SHARPNESS)))
        assertNull(analysis.details!!.photo)
        assertNull(analysis.details!!.layout)
        assertNull(analysis.faces)
        assertNull(analysis.confidence(Tags.DOG))
        assertTrue(analysis.details!!.sharpness!!.score in 0.0..1.0)
    }
}
