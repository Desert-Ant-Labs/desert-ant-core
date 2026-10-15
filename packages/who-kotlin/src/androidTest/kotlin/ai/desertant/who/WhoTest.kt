package ai.desertant.who

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Fast instrumented smoke for the Android binding, so who stays in the
 * every-commit device lane without its model. The suite never downloads: it
 * proves the part only a device can, that libWhoAndroid.so, the static Swift
 * runtime, and LiteRT load, and that a handle created through the shared core
 * crosses JNI and releases cleanly. Anything needing the weights lives in the
 * evaluation harness beside the training run, as with the Swift suite.
 */
@RunWith(AndroidJUnit4::class)
class WhoTest {
    private lateinit var who: Who

    // An empty scratch directory, so nothing can mistake a previously cached
    // model for this suite's state, and no call here can start a download.
    @Before fun setUp() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val scratch = File(context.cacheDir, "who-smoke").apply { deleteRecursively(); mkdirs() }
        who = Who(context, scratch.absolutePath)
    }

    // Null-safe: if setUp() throws, an unguarded close() replaces the real
    // failure with UninitializedPropertyAccessException and hides the cause.
    @After fun tearDown() { if (::who.isInitialized) who.close() }

    /** Construction loads the natives; the query round-trips the handle. */
    @Test fun createsAgainstAnEmptyDirectory() {
        assertFalse("an empty directory must not count as downloaded", who.isDownloaded())
    }

    /** Input validation fails before anything could touch the model. */
    @Test fun rejectsInvalidInput() = runTest {
        try {
            who.diarize(FloatArray(0))
            fail("empty samples must throw")
        } catch (expected: IllegalArgumentException) {}
        try {
            who.diarize(floatArrayOf(0f), sampleRate = 0.0)
            fail("a zero sample rate must throw")
        } catch (expected: IllegalArgumentException) {}
    }

    @Test fun refusesUseAfterClose() {
        who.close()
        try {
            who.isDownloaded()
            fail("a closed diarizer must throw")
        } catch (expected: WhoException) {}
    }

    /** The share rule is pure Kotlin and mirrors the Swift SDK's. */
    @Test fun hidesSpeakersUnderAShare() {
        val result = Diarization(
            listOf(Turn(0, 0.0, 50.0), Turn(1, 50.0, 90.0), Turn(2, 90.0, 92.0)),
            speakerCount = 3,
            duration = 100.0,
        )
        assertEquals(listOf(0, 1), result.speakers(minimumShare = 0.05))
        val kept = result.keepingSpeakers(minimumShare = 0.05)
        assertEquals(2, kept.speakerCount)
        assertEquals(listOf(Turn(0, 0.0, 50.0), Turn(1, 50.0, 90.0)), kept.turns)
        assertEquals(result, result.keepingSpeakers(minimumShare = 0.0))
    }
}
