package ai.desertant.emo

import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented tests for the Android binding, exercising the real on-device path
 * via JNI: platform JSON via CHostBridge, LiteRT inference, and the
 * static-stdlib runtime. The bundled model comes from the
 * `emo-tflite-resources` androidTest dependency.
 */
@RunWith(AndroidJUnit4::class)
class EmoTest {
    private lateinit var emo: Emo

    @Before fun setUp() { emo = Emo.bundled() }
    @After fun tearDown() { emo.close() }

    @Test fun suggestsForEnglishPhrase() = runTest {
        val suggestions = emo.suggestions("Pay my bills", limit = 5)
        assertTrue("expected suggestions", suggestions.isNotEmpty())
        assertTrue("got ${suggestions.map { it.emoji }}",
            suggestions.any { it.emoji in listOf("💰", "💳", "🧾", "🏦", "📄") })
    }

    @Test fun ranksByConfidence() = runTest {
        val suggestions = emo.suggestions("book a flight to Tokyo", limit = 3)
        assertEquals(3, suggestions.size)
        assertTrue(suggestions[0].confidence >= suggestions[1].confidence)
        assertTrue(suggestions.all { it.confidence in 0.0..1.0 })
    }

    @Test fun emptyInputReturnsEmpty() = runTest {
        assertTrue(emo.suggestions("   ").isEmpty())
    }
}
