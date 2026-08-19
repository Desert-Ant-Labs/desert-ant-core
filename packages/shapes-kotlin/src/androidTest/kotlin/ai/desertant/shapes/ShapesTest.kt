package ai.desertant.shapes

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/**
 * Instrumented tests for the Android binding, exercising the real on-device path
 * via JNI: platform JSON via CHostBridge, LiteRT inference, and the
 * static-stdlib runtime. No model ships with the AAR, so the model is downloaded
 * into the instrumentation app's cache on the first run and reused afterward.
 */
@RunWith(AndroidJUnit4::class)
class ShapesTest {
    private lateinit var shapes: Shapes

    @Before fun setUp() {
        shapes = Shapes(ApplicationProvider.getApplicationContext())
        runBlocking { shapes.download() }   // fetch once up front; cached afterward
    }
    // Null-safe: if setUp() throws, an unguarded close() replaces the real
    // failure with UninitializedPropertyAccessException and hides the cause.
    @After fun tearDown() { if (::shapes.isInitialized) shapes.close() }

    private fun circle() = (0..64).map {
        val t = 2.0 * Math.PI * it / 64.0
        Point(100 + 80 * cos(t), 100 + 80 * sin(t))
    }

    @Test fun recognizesCircleAsEllipseWithFit() = runTest {
        val shape = shapes.recognize(circle())
        assertNotNull(shape)
        assertTrue("expected ellipse, got $shape", shape is Shape.Ellipse)
        val ellipse = shape as Shape.Ellipse
        assertTrue("center ${ellipse.center}", abs(ellipse.center.x - 100) < 8)
        assertTrue("semiMajor ${ellipse.semiMajor}", abs(ellipse.semiMajor - 80) < 12)
    }

    @Test fun recognizesLine() = runTest {
        val shape = shapes.recognize((0..40).map { Point(it * 5.0, it * 2.0) })
        assertTrue("expected line, got $shape", shape is Shape.Line)
    }

    @Test fun degenerateReturnsNull() = runTest {
        assertNull(shapes.recognize(listOf(Point(1.0, 1.0))))
    }

    @Test fun minimumConfidenceRejects() = runTest {
        assertNull(shapes.recognize(circle(), Options(minimumConfidence = 1.0)))
    }
}
