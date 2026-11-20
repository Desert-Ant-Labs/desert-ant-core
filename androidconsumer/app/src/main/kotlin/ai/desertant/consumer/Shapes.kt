package ai.desertant.consumer

import ai.desertant.shapes.Options
import ai.desertant.shapes.Point
import ai.desertant.shapes.Rotation
import ai.desertant.shapes.Shape
import ai.desertant.shapes.Shapes
import android.content.Context

suspend fun shapes(context: Context, stroke: List<Point>): Shape.Kind? = Shapes(context).use { shapes ->
    if (!shapes.isDownloaded()) shapes.download()
    val shape = shapes.recognize(stroke, Options(rotation = Rotation.SNAPPED, kinds = Shape.Kind.entries.toSet()))
    if (shape is Shape.Line) println("${shape.from} ${shape.to}")
    shape?.kind
}
