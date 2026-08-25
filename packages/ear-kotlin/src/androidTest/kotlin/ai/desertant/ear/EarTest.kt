package ai.desertant.ear

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

/**
 * Instrumented tests for the Android binding, exercising the real on-device path
 * via JNI: the LiteRT runtime, the Swift frontend, and the static-stdlib
 * runtime. The AAR ships no model, so the suite downloads the pinned revision
 * into the app cache once and reuses it.
 */
@RunWith(AndroidJUnit4::class)
class EarTest {
    private lateinit var ear: Ear

    @Before fun setUp() {
        ear = Ear(InstrumentationRegistry.getInstrumentation().targetContext)
    }
    // Null-safe: if setUp() throws, an unguarded close() replaces the real
    // failure with UninitializedPropertyAccessException and hides the cause.
    @After fun tearDown() { if (::ear.isInitialized) ear.close() }

    /**
     * The same signal the reference fixture was produced from: a linear
     * congruential generator shaped by a 4 Hz syllable envelope. Written out
     * rather than randomised so the two sides compare like for like - a random
     * signal would only prove that something came back.
     */
    private fun parityAudio(seconds: Int = 40, sampleRate: Int = 16_000): FloatArray {
        var seed = 12_345L
        return FloatArray(seconds * sampleRate) { i ->
            seed = (seed * 1_103_515_245 + 12_345) and 0x7fffffff
            val noise = (seed.toFloat() / 0x7fffffff - 0.5f) * 2f
            val syllable = 0.5 + 0.5 * sin(2 * PI * 4 * i / sampleRate)
            (syllable * 0.3 * noise).toFloat()
        }
    }

    private fun fixture(): JSONObject {
        val context = InstrumentationRegistry.getInstrumentation().context
        val text = context.assets.open("ear-parity.json").bufferedReader().use { it.readText() }
        return JSONObject(text)
    }

    /**
     * The test that matters: the same audio through JNI must give the answer the
     * Swift SDK gave. Anything else means the frontend, the runtime or the
     * payload differs on this platform, and a language that is merely plausible
     * would hide all three.
     */
    @Test fun matchesTheReferenceOutput() = runTest {
        val expected = fixture()
        val detection = ear.identify(parityAudio())

        val candidates = expected.getJSONArray("candidates")
        val top = candidates.getJSONObject(0)
        assertEquals("top language differs from the reference",
            top.getString("language"), detection.language)
        assertTrue(
            "probability ${detection.confidence} differs from the reference " +
                "${top.getDouble("probability")}",
            abs(detection.confidence - top.getDouble("probability")) < 0.01)
        assertEquals("window count differs",
            expected.getInt("windows"), detection.windows)
        assertEquals("reliability verdict differs",
            expected.getBoolean("isReliable"), detection.isReliable)

        // The whole ranking, not just the winner: a frontend that is subtly
        // wrong can still put the same language first.
        for (i in 0 until minOf(candidates.length(), detection.candidates.size)) {
            val want = candidates.getJSONObject(i)
            assertEquals("candidate $i language differs",
                want.getString("language"), detection.candidates[i].language)
            assertTrue("candidate $i probability differs",
                abs(detection.candidates[i].probability - want.getDouble("probability")) < 0.01)
        }
    }

    @Test fun reportsWhetherTheModelIsPresent() = runTest {
        ear.download()
        assertTrue("the model reports itself missing after a successful download",
            ear.isDownloaded())
    }

    @Test fun namesALanguageAndRanksTheCandidates() = runTest {
        val detection = ear.identify(parityAudio(seconds = 40))
        assertNotNull(detection.language)
        assertTrue(detection.confidence > 0.0 && detection.confidence <= 1.0)
        assertTrue(detection.windows >= 1)
        val probabilities = detection.candidates.map { it.probability }
        assertEquals("candidates are not ranked",
            probabilities.sortedDescending(), probabilities)
        assertEquals(probabilities.first(), detection.confidence, 1e-12)
    }

    @Test fun windowCountReachesTheModel() = runTest {
        val one = ear.identify(parityAudio(seconds = 120), options = Options(windows = 1))
        val three = ear.identify(parityAudio(seconds = 120), options = Options(windows = 3))
        assertEquals(1, one.windows)
        assertTrue("expected more than one window, got ${three.windows}", three.windows > 1)
    }

    @Test fun resamplesRatherThanRefusing() = runTest {
        val detection = ear.identify(parityAudio(seconds = 40), sampleRate = 44_100.0)
        assertNotNull(detection.language)
        assertTrue(detection.windows >= 1)
    }

    @Test fun emptyAudioIsRejected() = runTest {
        var threw = false
        try {
            ear.identify(FloatArray(0))
        } catch (e: IllegalArgumentException) {
            threw = true
        }
        assertTrue("empty audio should be rejected rather than guessed at", threw)
    }

    @Test fun anUnreliableAnswerStillReportsItsLanguage() = runTest {
        // The fixture's own answer is unreliable, which is the case worth
        // pinning: unreliable means "do not route work on this", not "hide it".
        val detection = ear.identify(parityAudio())
        assertFalse(detection.isReliable)
        assertNotNull(detection.language)
    }
}
