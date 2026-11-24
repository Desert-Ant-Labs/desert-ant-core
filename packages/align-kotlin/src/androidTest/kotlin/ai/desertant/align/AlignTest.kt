package ai.desertant.align

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.PI
import kotlin.math.sin

// Runs the real JNI path (LiteRT, the Swift refiner, the payload codec) against the pinned revision, downloaded once into the app cache.
@RunWith(AndroidJUnit4::class)
class AlignTest {
    private lateinit var align: Align

    @Before fun setUp() {
        align = Align(InstrumentationRegistry.getInstrumentation().targetContext)
    }
    @After fun tearDown() { if (::align.isInitialized) align.close() }

    private val words = listOf(Word("hola", 0.4, 0.71), Word("mundo", 0.8, 1.3))

    private fun tone(seconds: Int = 3, sampleRate: Int = 16_000) = FloatArray(seconds * sampleRate) { i ->
        (0.3 * sin(2 * PI * 200 * i / sampleRate)).toFloat()
    }

    @Test fun reportsWhetherTheModelIsPresent() = runTest {
        align.download()
        assertTrue(align.isDownloaded())
    }

    @Test fun languagesFollowTheSwiftKeyRule() {
        assertEquals(9, Align.languages.size)
        assertTrue(Align.isSupported("pt-BR"))
        assertTrue(Align.isSupported("EN"))
        assertFalse(Align.isSupported("xx"))
    }

    @Test fun refinesATranscript() = runTest {
        val out = align.refine(tone(), words = words, language = "es")
        assertEquals(words.map { it.text }, out.map { it.text })
        assertTrue("$out", out[0].start < out[0].end)
        assertTrue("no word was refined: the native core ran nothing", out.any { it.refined })
    }

    @Test fun cascadeMatchesTheSwiftGolden() = runTest {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val golden = assets.open("golden.json").bufferedReader().use { JSONObject(it.readText()) }
        val sampleRate = golden.getDouble("sample_rate")
        val audio = FloatArray(golden.getInt("n_samples")) { index ->
            val t = index / sampleRate
            val twoPi = 2.0 * PI
            (0.3 * sin(twoPi * 200 * t) + 0.2 * sin(twoPi * 350 * t) +
                0.1 * sin(twoPi * 61 * t) * sin(twoPi * 3 * t)).toFloat()
        }
        val input = golden.getJSONArray("words")
        val words = List(input.length()) { index ->
            val word = input.getJSONObject(index)
            Word(word.getString("text"), word.getDouble("start"), word.getDouble("end"))
        }
        val corrections = golden.getJSONArray("corrections")
        assertEquals(words.size * 2, corrections.length())
        val actual = align.refine(audio, sampleRate = sampleRate, words = words, language = golden.getString("language"))
        assertEquals(words.map { it.text }, actual.map { it.text })

        // Match the Swift LiteRT budget. This fixture records corrections in seconds.
        val tolerance = 0.015
        for ((index, word) in words.withIndex()) {
            val start = corrections.getDouble(index * 2)
            val end = corrections.getDouble(index * 2 + 1)
            val result = actual[index]
            assertTrue("${word.text}: expected a refined word", result.refined)
            assertEquals("${word.text} start correction (s)", start, result.start - word.start, tolerance)
            assertEquals("${word.text} end correction (s)", end, result.end - word.end, tolerance)
        }
    }

    // The core normalizes each word to NFC through the host: a decomposed and a composed spelling are the same bytes to the model.
    @Test fun decomposedAndComposedTextRefineAlike() = runTest {
        val composed = listOf(Word("año", 0.4, 0.71), Word("niño", 0.8, 1.3))
        val decomposed = listOf(Word("año", 0.4, 0.71), Word("niño", 0.8, 1.3))
        val a = align.refine(tone(), words = composed, language = "es")
        val b = align.refine(tone(), words = decomposed, language = "es")
        assertEquals(a.map { it.start to it.end }, b.map { it.start to it.end })
    }

    @Test fun anUnsupportedLanguageIsAPassthrough() = runTest {
        val out = align.refine(tone(), words = words, language = "xx")
        assertEquals(words, out)
    }

    @Test fun resamplesRatherThanRefusing() = runTest {
        val out = align.refine(tone(sampleRate = 44_100), sampleRate = 44_100.0, words = words, language = "es")
        assertEquals(2, out.size)
    }

    @Test fun badInputIsRejected() = runTest {
        for (call in listOf<suspend () -> Unit>(
            { align.refine(FloatArray(0), words = words, language = "es") },
            { align.refine(tone(), sampleRate = Double.NaN, words = words, language = "es") },
            // 16,000 samples at 0.01 Hz resample to 25.6 billion, past the core's Int32 limit.
            { align.refine(tone(seconds = 1), sampleRate = 0.01, words = words, language = "es") },
            { align.refine(tone(), words = listOf(Word("hola", Double.NaN, 0.7)), language = "es") },
        )) {
            var threw = false
            try { call() } catch (e: IllegalArgumentException) { threw = true }
            assertTrue(threw)
        }
    }
}
