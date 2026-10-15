package ai.desertant.voz

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Fast instrumented smoke for the Android binding, so voz stays in the
 * every-commit device lane without its multi-gigabyte model. The suite never
 * downloads: it proves the part only a device can, that libVozAndroid.so, the
 * static Swift runtime, and LiteRT load, and that a handle created through the
 * shared core crosses JNI and releases cleanly. Anything needing the weights
 * lives in the evaluation harness beside the training run, as with the Swift
 * suite.
 */
@RunWith(AndroidJUnit4::class)
class VozTest {
    private lateinit var voz: Voz

    // An empty scratch directory, so nothing can mistake a previously cached
    // model for this suite's state, and no call here can start a download.
    @Before fun setUp() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val scratch = File(context.cacheDir, "voz-smoke").apply { deleteRecursively(); mkdirs() }
        voz = Voz(context, scratch.absolutePath)
    }

    // Null-safe: if setUp() throws, an unguarded close() replaces the real
    // failure with UninitializedPropertyAccessException and hides the cause.
    @After fun tearDown() { if (::voz.isInitialized) voz.close() }

    /** Construction loads the natives; the query round-trips the handle. */
    @Test fun createsAgainstAnEmptyDirectory() {
        assertFalse("an empty directory must not count as downloaded", voz.isDownloaded())
    }

    /** Input validation fails before anything could touch the model. */
    @Test fun rejectsInvalidInput() = runTest {
        try {
            voz.transcribe(FloatArray(0))
            fail("empty samples must throw")
        } catch (expected: IllegalArgumentException) {}
        try {
            voz.transcribe(floatArrayOf(0f), sampleRate = 0.0)
            fail("a zero sample rate must throw")
        } catch (expected: IllegalArgumentException) {}
    }

    @Test fun refusesUseAfterClose() {
        voz.close()
        try {
            voz.isDownloaded()
            fail("a closed recognizer must throw")
        } catch (expected: VozException) {}
    }
}
