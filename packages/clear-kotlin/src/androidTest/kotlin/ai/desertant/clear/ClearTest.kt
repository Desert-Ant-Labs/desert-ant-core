package ai.desertant.clear

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.PI
import kotlin.math.sin

/**
 * Instrumented tests for the Android binding, exercising the real on-device path
 * via JNI: the LiteRT runtime, the DSP front end, and the static-stdlib runtime.
 * The AAR ships no model, so the suite downloads the pinned revision into the
 * app cache once and reuses it.
 */
@RunWith(AndroidJUnit4::class)
class ClearTest {
    private lateinit var clear: Clear

    @Before fun setUp() {
        clear = Clear(InstrumentationRegistry.getInstrumentation().targetContext)
    }
    // Null-safe: if setUp() throws, an unguarded close() replaces the real
    // failure with UninitializedPropertyAccessException and hides the cause.
    @After fun tearDown() { if (::clear.isInitialized) clear.close() }

    /** A second of tone plus noise: enough frames for several model chunks. */
    private fun noisyTone(seconds: Double = 1.0, sampleRate: Int = 48_000): FloatArray {
        var seed = 12_345L
        return FloatArray((seconds * sampleRate).toInt()) { i ->
            seed = (seed * 1_103_515_245 + 12_345) and 0x7fffffff
            val noise = (seed.toFloat() / 0x7fffffff - 0.5f) * 0.1f
            (0.3 * sin(2 * PI * 220 * i / sampleRate)).toFloat() + noise
        }
    }

    @Test fun enhanceEndToEnd() = runTest {
        val r = clear.enhance(noisyTone())
        assertEquals(48_000.0, r.sampleRate, 0.0)
        assertTrue(r.samples.isNotEmpty())
        assertTrue(r.samples.all { it.isFinite() })
        assertTrue(r.durationSec > 0)
    }

    @Test fun masteringReportsBothMeasurements() = runTest {
        val r = clear.enhance(
            noisyTone(),
            options = Options(mastering = Mastering.of(LoudnessPreset.SPOTIFY)),
        )
        assertNotNull(r.measuredLufs)
        val truePeak = r.measuredTruePeakDbfs
        assertNotNull(truePeak)
        // Limited to the default -1.5 dBTP ceiling, with a little slack for the
        // inter-sample peaks a sample-peak limiter does not see.
        assertTrue("true peak $truePeak above ceiling", truePeak!! <= -1.0)
    }

    @Test fun bypassReportsNoMeasurements() = runTest {
        val r = clear.enhance(noisyTone(), options = Options(mastering = Mastering.BYPASS))
        assertNull(r.measuredLufs)
        assertNull(r.measuredTruePeakDbfs)
    }
}
