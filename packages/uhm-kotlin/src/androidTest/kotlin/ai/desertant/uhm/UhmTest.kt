package ai.desertant.uhm

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

// Runs the real JNI path (LiteRT, the Swift detector, the payload codec) against the pinned revision, downloaded once into the app cache.
@RunWith(AndroidJUnit4::class)
class UhmTest {
    private lateinit var uhm: Uhm

    @Before fun setUp() {
        uhm = Uhm(InstrumentationRegistry.getInstrumentation().targetContext)
    }
    @After fun tearDown() { if (::uhm.isInitialized) uhm.close() }

    private fun silence(seconds: Int = 2, sampleRate: Int = 16_000) = FloatArray(seconds * sampleRate) { 0.001f }

    private fun syllables(seconds: Int = 4, sampleRate: Int = 16_000) = FloatArray(seconds * sampleRate) { i ->
        val t = i.toDouble() / sampleRate
        ((0.5 + 0.5 * sin(2 * PI * 4 * t)) * 0.2 * sin(2 * PI * 180 * t)).toFloat()
    }

    @Test fun reportsWhetherTheModelIsPresent() = runTest {
        uhm.download()
        assertTrue(uhm.isDownloaded())
    }

    @Test fun silenceHasADurationAndNoFillers() = runTest {
        val result = uhm.detect(silence())
        assertTrue(abs(result.audioDuration - 2.0) < 0.05)
        assertEquals(emptyList<Filler>(), result.fillers)
        assertNull(result.words)
    }

    @Test fun fillersStayInsideTheAudioWithoutTypes() = runTest {
        val result = uhm.detect(syllables(), options = Options(bias = Bias.RECALL))
        assertTrue(abs(result.audioDuration - 4.0) < 0.05)
        for (f in result.fillers) {
            assertTrue("$f", f.start >= 0 && f.end <= 4.0 && f.end > f.start)
            assertTrue("$f", f.confidence > 0 && f.confidence <= 1)
            assertNull(f.type)
        }
    }

    @Test fun wordsComeBackReconciled() = runTest {
        val result = uhm.detect(silence(), words = listOf(Word(0.1, 0.5, "hi"), Word(1.0, 1.0, "void")))
        assertEquals(listOf(Word(0.1, 0.5, "hi")), result.words)
    }

    @Test fun resamplesRatherThanRefusing() = runTest {
        val result = uhm.detect(FloatArray(44_100) { 0.001f }, sampleRate = 44_100.0)
        assertTrue(abs(result.audioDuration - 1.0) < 0.05)
    }

    @Test fun emptyAudioIsRejected() = runTest {
        var threw = false
        try {
            uhm.detect(FloatArray(0))
        } catch (e: IllegalArgumentException) {
            threw = true
        }
        assertTrue(threw)
    }
}
