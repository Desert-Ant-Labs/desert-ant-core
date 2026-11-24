package ai.desertant.who

import ai.desertant.androidtest.readSpeechFixture
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WhoSpeechParityTest {
    @Test fun matchesTheLibriVoxTurnReference() = runBlocking {
        assumeTrue("set DAL_SPEECH_PARITY=1", InstrumentationRegistry.getArguments().getString("DAL_SPEECH_PARITY") == "1")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val assets = instrumentation.context.assets
        val samples = assets.readSpeechFixture("speech.wav")
        val golden = assets.open("who_speech_sdk_golden.json").bufferedReader().use { JSONObject(it.readText()) }
        val expected = golden.getJSONArray("speakers")
        Who(instrumentation.targetContext).use { who ->
            val result = who.diarize(samples)
            assertEquals(golden.getDouble("duration"), result.duration, 0.01)
            assertEquals(expected.length(), result.speakerCount)
            assertEquals(result.turns.sortedBy { it.start }, result.turns)
            assertTrue("turns outside audio: $result", result.turns.all {
                it.start >= 0 && it.start < it.end && it.end <= result.duration + 0.01
            })
            // Speaker ids are arbitrary. Match this fixture's speakers by their first turn.
            val speakers = result.turns.groupBy { it.speaker }.values.sortedBy { it.first().start }
            assertEquals(expected.length(), speakers.size)
            for ((index, turns) in speakers.withIndex()) {
                val spans = expected.getJSONArray(index)
                assertEquals(spans.length(), turns.size)
                for ((rank, turn) in turns.withIndex()) {
                    val span = spans.getJSONObject(rank)
                    assertEquals("speaker $index turn $rank start", span.getDouble("start"), turn.start, 0.06)
                    assertEquals("speaker $index turn $rank end", span.getDouble("end"), turn.end, 0.06)
                }
            }
        }
    }
}
