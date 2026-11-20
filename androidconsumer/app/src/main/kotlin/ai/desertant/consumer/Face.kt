package ai.desertant.consumer

import ai.desertant.core.Faceprint
import ai.desertant.face.Face
import ai.desertant.face.FaceDetector
import ai.desertant.face.FaceRecord
import ai.desertant.face.Options
import android.content.Context
import android.graphics.Bitmap

suspend fun face(context: Context, photos: List<Bitmap>): List<Int> = Face(context).use { face ->
    if (!face.isDownloaded()) face.download()
    FaceDetector(context).use { detector ->
        photos.forEach { println(detector.faces(it, Options(minimumConfidence = 0.5)).size) }
    }
    val library = face.library()
    photos.forEachIndexed { i, photo -> library.add(face.faces(photo), photo = "photo-$i") }
    library.regroup()
    val rows: List<FaceRecord> = library.takeChanges()
    val people = library.people(prominent = true)
    people.forEach { println("${it.id} ${it.name} ${it.photoCount} ${it.keyFace}") }
    val reference: Faceprint? = rows.firstOrNull()?.faceprint
    if (reference != null) println(Face.matches(reference, rows.map { it.faceprint }).size)
    val names = library.names()
    library.close()
    face.library(rows, names).close()
    people.map { it.id }
}
