package ai.desertant.shapes

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs
import kotlin.math.atan2
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

    /** Densely trace a polyline through [vertices]. */
    private fun trace(vararg vertices: Point, per: Int = 10): List<Point> =
        vertices.toList().zipWithNext().flatMap { (a, b) ->
            (0 until per).map { s -> Point(a.x + (b.x - a.x) * s / per, a.y + (b.y - a.y) * s / per) }
        } + vertices.last()

    private fun arrow() = trace(Point(0.0, 100.0), Point(200.0, 100.0), Point(170.0, 82.0),
        Point(200.0, 100.0), Point(170.0, 118.0), per = 8)

    private fun zigzag() = trace(*Array(8) { Point(it * 18.0, if (it % 2 == 0) 0.0 else 80.0) })

    private fun box(degrees: Double): List<Point> {
        val a = Math.toRadians(degrees)
        return trace(Point(0.0, 0.0), Point(160.0, 0.0), Point(160.0, 90.0), Point(0.0, 90.0), Point(0.0, 0.0), per = 24)
            .map { Point(80 + (it.x - 80) * cos(a) - (it.y - 45) * sin(a), 45 + (it.x - 80) * sin(a) + (it.y - 45) * cos(a)) }
    }

    @Test fun recognizesCircleAsACircle() = runTest {
        val shape = shapes.recognize(circle())
        assertTrue("expected ellipse, got $shape", shape is Shape.Ellipse)
        val ellipse = shape as Shape.Ellipse
        assertTrue("center ${ellipse.center}", abs(ellipse.center.x - 100) < 4)
        assertTrue("semiMajor ${ellipse.semiMajor}", abs(ellipse.semiMajor - 80) < 4)
        assertEquals(ellipse.semiMajor, ellipse.semiMinor, 0.0)
        assertEquals(64, ellipse.outline.size)
    }

    @Test fun recognizesLine() = runTest {
        val shape = shapes.recognize((0..40).map { Point(it * 5.0, it * 2.0) })
        assertTrue("expected line, got $shape", shape is Shape.Line)
    }

    @Test fun arrowKeepsItsHead() = runTest {
        val shape = shapes.recognize(arrow())
        assertTrue("expected arrow, got $shape", shape is Shape.Arrow)
        val a = shape as Shape.Arrow
        assertTrue(a.endHead && !a.startHead)
        val heads = a.arrowheads(12.0)
        assertEquals(1, heads.size)
        assertEquals(a.to, heads[0][1])
    }

    @Test fun zigzagIsAScribbleUnlessLeftOut() = runTest {
        val shape = shapes.recognize(zigzag())
        assertTrue("expected scribble, got $shape", shape is Shape.Scribble)
        assertTrue((shape as Shape.Scribble).hull.size >= 3)
        assertNull(shapes.recognize(zigzag(), Options(kinds = Shape.Kind.entries.toSet() - Shape.Kind.SCRIBBLE)))
    }

    @Test fun uprightRemovesRotation() = runTest {
        val shape = shapes.recognize(box(22.0), Options(rotation = Rotation.UPRIGHT))
        assertTrue("expected rectangle, got $shape", shape is Shape.Rectangle)
        val c = (shape as Shape.Rectangle).corners
        val angle = Math.toDegrees(atan2(c[1].y - c[0].y, c[1].x - c[0].x))
        assertTrue("angle $angle", abs(angle % 90.0) < 1e-6)
    }

    @Test fun degenerateReturnsNull() = runTest {
        assertNull(shapes.recognize(listOf(Point(1.0, 1.0))))
    }

    @Test fun minimumConfidenceRejects() = runTest {
        assertNull(shapes.recognize(circle(), Options(minimumConfidence = 1.0)))
    }
}
