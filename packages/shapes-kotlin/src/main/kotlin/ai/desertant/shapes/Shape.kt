package ai.desertant.shapes

/** A 2D point in the same coordinate space as the input stroke. */
data class Point(val x: Double, val y: Double)

/**
 * A recognized, fitted shape in the same coordinate space as the input stroke.
 * Mirrors the Swift/TypeScript `Shape` types.
 */
sealed class Shape {
    /** A straight line segment from [from] to [to]. */
    data class Line(val from: Point, val to: Point) : Shape()

    /** A rectangle given by its four corners, in order around the perimeter. */
    data class Rectangle(val corners: List<Point>) : Shape()

    /** A triangle given by its three vertices. */
    data class Triangle(val vertices: List<Point>) : Shape()

    /** An ellipse with the given [center], semi-axes, and [rotation] (radians). */
    data class Ellipse(
        val center: Point,
        val semiMajor: Double,
        val semiMinor: Double,
        val rotation: Double,
    ) : Shape()

    /**
     * A star alternating between [outerRadius] and [innerRadius] across
     * [pointCount] points, with [rotation] in radians.
     */
    data class Star(
        val center: Point,
        val outerRadius: Double,
        val innerRadius: Double,
        val rotation: Double,
        val pointCount: Int,
    ) : Shape()
}
