package ai.desertant.moderator

import android.graphics.BitmapFactory
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
import java.net.URL
import java.security.MessageDigest
import kotlin.math.abs

/**
 * Instrumented tests over the real on-device path: JNI, the Swift core, and
 * LiteRT. Expected scores are the reference goldens the Swift and Node suites
 * check (Tests/ModeratorTests/Resources, packaged as test assets). The model is
 * adopted from the test assets when a local export was packaged
 * (MODERATOR_MODEL_DIR at build time), else downloaded at the pinned revision.
 */
@RunWith(AndroidJUnit4::class)
class ModeratorTest {
    private lateinit var moderator: Moderator
    private val assets = InstrumentationRegistry.getInstrumentation().context.assets
    private val golden by lazy { JSONObject(assets.open("moderator_golden.json").bufferedReader().readText()) }

    @Before fun setUp() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val directory = if ("moderator.tflite" in assets.list("").orEmpty()) {
            File(context.cacheDir, "moderator-local").apply {
                mkdirs()
                assets.open("moderator.tflite").use { src -> File(this, "moderator.tflite").outputStream().use { src.copyTo(it) } }
            }.path
        } else null
        moderator = Moderator(context, directory)
        runBlocking { moderator.download() }
    }

    @After fun tearDown() { if (::moderator.isInitialized) moderator.close() }

    private fun synthetic(width: Int, height: Int): ByteArray {
        val out = ByteArray(width * height * 3)
        for (y in 0 until height) for (x in 0 until width) {
            val i = (y * width + x) * 3
            out[i] = (((x * 7 + y * 13) xor (x * y)) and 255).toByte()
            out[i + 1] = ((x * 3 + y * 5) and 255).toByte()
            out[i + 2] = (((x xor y) * 11) and 255).toByte()
        }
        return out
    }

    private fun assertClose(got: Regions, want: JSONObject, tolerance: Double) {
        val pairs = listOf(got.nipples to "nipples", got.genitals to "genitals", got.buttocks to "buttocks",
            got.nude to "nude", got.sexAct to "sexAct")
        for ((value, key) in pairs) {
            assertTrue("$key: got $value, want ${want.getDouble(key)}", abs(value - want.getDouble(key)) < tolerance)
        }
    }

    @Test fun syntheticMatchesReference() = runTest {
        val s = golden.getJSONObject("synthetic")
        val (w, h) = s.getInt("width") to s.getInt("height")
        for (quality in Quality.entries) {
            val result = moderator.analyze(synthetic(w, h), w, h, Options(quality = quality))
            assertClose(result.regions, s.getJSONObject(quality.name.lowercase()), 0.02)
        }
    }

    @Test fun swimwearFixtureIsSafe() = runTest {
        val sfw = golden.getJSONObject("sfw")
        val bitmap = assets.open(sfw.getString("file")).use { BitmapFactory.decodeStream(it) }
        for (quality in Quality.entries) {
            val result = moderator.analyze(bitmap, Options(quality = quality))
            assertClose(result.regions, sfw.getJSONObject(quality.name.lowercase()), 0.02)
            assertFalse(result.isNSFW)
        }
    }

    /** A public-domain nude painting (Courbet), downloaded, never committed. */
    @Test fun nudePaintingIsFlagged() = runTest {
        val positive = golden.getJSONObject("positive")
        val bytes = URL(positive.getString("url")).openConnection().apply {
            setRequestProperty("User-Agent", "DesertAntLabs-moderator-tests/1.0 (licensing@desertant.com)")
        }.getInputStream().use { it.readBytes() }
        val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        assertEquals(positive.getString("sha256"), sha)
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        val result = moderator.analyze(bitmap)
        assertTrue("score ${result.score}", result.isNSFW)
        assertClose(result.regions, positive.getJSONObject("accurate"), 0.05)
        assertFalse(moderator.analyze(bitmap, Options(threshold = 0.99)).isNSFW)
    }

    @Test fun rejectsMismatchedPixels() {
        val error = runCatching { runBlocking { moderator.analyze(ByteArray(5), 2, 2) } }.exceptionOrNull()
        assertTrue(error is IllegalArgumentException)
    }
}
