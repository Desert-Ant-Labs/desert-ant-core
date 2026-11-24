package ai.desertant.voz

import ai.desertant.androidtest.readSpeechFixture
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class VozSpeechParityTest {
    @Test fun transcribesLibriVoxSpeechWithWordTimings() = runBlocking {
        assumeTrue("set DAL_SPEECH_PARITY=1", InstrumentationRegistry.getArguments().getString("DAL_SPEECH_PARITY") == "1")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val samples = instrumentation.context.assets.readSpeechFixture("speech.wav")
        Voz(instrumentation.targetContext).use { voz ->
            val result = voz.transcribe(samples)
            val separators = Regex("[^a-z]+")
            val expectedPhrases = Regex("""\bpublic domain\b.*\bmore information\b""")
            for ((label, value) in listOf("transcript" to result.text, "timed words" to result.words.joinToString(" ") { it.text })) {
                val normalized = separators.replace(value.lowercase(), " ").trim()
                assertTrue("unexpected $label: $normalized", expectedPhrases.containsMatchIn(normalized))
            }
            assertEquals(samples.size / 16_000.0, result.duration, 0.01)
            assertTrue("only ${result.words.size} timed words", result.words.size > 5)
            assertEquals(result.words.sortedBy { it.start }, result.words)
            assertTrue("invalid word times: ${result.words}", result.words.all {
                it.text.isNotBlank() && it.start >= 0 && it.end >= it.start && it.end <= result.duration + 0.5
            })
            assertTrue("the last word must have an audio timestamp", result.words.last().start > 0.5)
        }
    }
}
