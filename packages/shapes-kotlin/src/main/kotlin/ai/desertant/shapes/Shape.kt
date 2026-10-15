package ai.desertant.shapes

import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/** A 2D point in the same coordinate space as the input stroke. */
data class Point(val x: Double, val y: Double)

/**
 * A recognized shape, in the same coordinates as the input stroke. The kinds
 * and field names match the Swift and TypeScript SDKs.
 *
 * Every shape has [outline], a polyline you can draw. A closed shape's outline
 * doesn't repeat its first point. A connector's outline runs from start to
 * end, and an arrow's outline is its shaft (see [Arrow.arrowheads]).
 */
sealed class Shape {
    abstract val outline: List<Point>
    abstract val kind: Kind

    /** What a shape is, without its geometry. */
    enum class Kind { LINE, CURVE, ARROW, RECTANGLE, ELLIPSE, TRIANGLE, DIAMOND, PENTAGON, HEXAGON, STAR, HEART, CLOUD, SCRIBBLE }

    /** A straight connector. */
    data class Line(val from: Point, val to: Point, override val outline: List<Point>) : Shape() {
        override val kind get() = Kind.LINE
    }

    /** A curved connector: a cubic Bezier from [from] to [to]. */
    data class Curve(
        val from: Point, val control1: Point, val control2: Point, val to: Point,
        override val outline: List<Point>,
    ) : Shape() {
        override val kind get() = Kind.CURVE
    }

    /**
     * A connector with a drawn head at one or both ends. The shaft is a cubic
     * Bezier. A straight arrow has its controls on the line.
     */
    data class Arrow(
        val from: Point, val control1: Point, val control2: Point, val to: Point,
        val startHead: Boolean, val endHead: Boolean,
        override val outline: List<Point>,
    ) : Shape() {
        override val kind get() = Kind.ARROW

        /** The heads, each an open polyline `[barb, tip, barb]` with barbs [length] long. */
        fun arrowheads(length: Double): List<List<Point>> {
            fun at(t: Double): Point {
                val u = 1 - t
                val k = doubleArrayOf(u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t)
                return Point(
                    k[0] * from.x + k[1] * control1.x + k[2] * control2.x + k[3] * to.x,
                    k[0] * from.y + k[1] * control1.y + k[2] * control2.y + k[3] * to.y,
                )
            }
            fun head(tip: Point, from: Point): List<Point> {
                val n = hypot(tip.x - from.x, tip.y - from.y).takeIf { it > 0 } ?: 1.0
                val bx = -(tip.x - from.x) / n
                val by = -(tip.y - from.y) / n
                fun barb(a: Double) = Point(
                    tip.x + length * (cos(a) * bx - sin(a) * by),
                    tip.y + length * (sin(a) * bx + cos(a) * by),
                )
                return listOf(barb(0.45), tip, barb(-0.45))
            }
            return buildList {
                if (startHead) add(head(from, at(2.0 / 32)))
                if (endHead) add(head(to, at(30.0 / 32)))
            }
        }
    }

    /** Four corners in order around the perimeter. */
    data class Rectangle(val corners: List<Point>, override val outline: List<Point>) : Shape() {
        override val kind get() = Kind.RECTANGLE
    }

    /** An ellipse. [rotation], in radians, is the angle of the [semiMajor] axis from +x. */
    data class Ellipse(
        val center: Point, val semiMajor: Double, val semiMinor: Double, val rotation: Double,
        override val outline: List<Point>,
    ) : Shape() {
        override val kind get() = Kind.ELLIPSE
    }

    /** Three vertices. */
    data class Triangle(val vertices: List<Point>, override val outline: List<Point>) : Shape() {
        override val kind get() = Kind.TRIANGLE
    }

    /** A rhombus: four vertices in order around the perimeter. */
    data class Diamond(val vertices: List<Point>, override val outline: List<Point>) : Shape() {
        override val kind get() = Kind.DIAMOND
    }

    /** Five vertices in order around the perimeter. */
    data class Pentagon(val vertices: List<Point>, override val outline: List<Point>) : Shape() {
        override val kind get() = Kind.PENTAGON
    }

    /** Six vertices in order around the perimeter. */
    data class Hexagon(val vertices: List<Point>, override val outline: List<Point>) : Shape() {
        override val kind get() = Kind.HEXAGON
    }

    /** A star. At [rotation] 0, in radians, a tip points straight up. */
    data class Star(
        val center: Point, val outerRadius: Double, val innerRadius: Double,
        val rotation: Double, val pointCount: Int,
        override val outline: List<Point>,
    ) : Shape() {
        override val kind get() = Kind.STAR
    }

    /** A heart that fills a [width] by [height] box around [center], with its point down. */
    data class Heart(
        val center: Point, val width: Double, val height: Double,
        override val outline: List<Point>,
    ) : Shape() {
        override val kind get() = Kind.HEART
    }

    /** A cloud. [outline] is the closed outline of its bumps. */
    data class Cloud(override val outline: List<Point>) : Shape() {
        override val kind get() = Kind.CLOUD
    }

    /**
     * The erase gesture. [hull] is the convex hull of the scribble. To erase,
     * delete the content inside the hull.
     */
    data class Scribble(val hull: List<Point>, override val outline: List<Point>) : Shape() {
        override val kind get() = Kind.SCRIBBLE
    }
}
