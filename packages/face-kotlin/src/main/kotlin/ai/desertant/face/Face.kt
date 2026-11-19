package ai.desertant.face

import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel
import android.graphics.Bitmap
import org.json.JSONArray
import org.json.JSONObject
import java.util.Date

private const val MODEL_ID = "face"
private const val MODEL_NAME = "Face"

/** A rectangle in `0..1` of the image's size, origin top left. */
data class Box(val x0: Double, val y0: Double, val x1: Double, val y1: Double) {
    val width: Double get() = x1 - x0
    val height: Double get() = y1 - y0
}

/** A point in `0..1` of the image's size, origin top left. */
data class Point(val x: Double, val y: Double)

/** A face [FaceDetector] found: where it is, without a faceprint. */
data class FaceDetection(
    val box: Box,
    /** Left eye, right eye, nose tip, left and right mouth corner. */
    val landmarks: List<Point>,
    val confidence: Double,
)

/** A face [Face] found, with its faceprint. */
data class DetectedFace(
    val box: Box,
    /** Left eye, right eye, nose tip, left and right mouth corner. */
    val landmarks: List<Point>,
    val confidence: Double,
    val faceprint: Faceprint,
) {
    /** Where the face is, without its faceprint. */
    val detection: FaceDetection get() = FaceDetection(box, landmarks, confidence)
}

/** One face in a [FaceLibrary]: one row of your own faces table. */
data class FaceRecord(
    val id: String,
    val photo: String,
    val date: Date? = null,
    val box: Box? = null,
    val confidence: Double,
    val faceprint: Faceprint,
    val person: Int? = null,
    val confirmed: Boolean = false,
    val rejected: Set<Int> = emptySet(),
) {
    /** The portable JSON form, the one [FaceLibrary.save] writes and [Face.library] reads. */
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("photo", photo)
        date?.let { put("date", it.time / 1000.0) }
        box?.let { put("box", it.toJson()) }
        put("confidence", confidence)
        put("faceprint", faceprint.toJson())
        person?.let { put("person", it) }
        put("confirmed", confirmed)
        put("rejected", JSONArray(rejected.sorted()))
    }

    companion object {
        @JvmStatic
        fun fromJson(j: JSONObject): FaceRecord = FaceRecord(
            id = j.getString("id"),
            photo = j.getString("photo"),
            date = if (j.has("date") && !j.isNull("date")) Date((j.getDouble("date") * 1000).toLong()) else null,
            box = j.optJSONObject("box")?.toBox(),
            confidence = j.getDouble("confidence"),
            faceprint = Faceprint.fromJson(j.getJSONObject("faceprint")),
            person = if (j.has("person") && !j.isNull("person")) j.getInt("person") else null,
            confirmed = j.optBoolean("confirmed", false),
            rejected = j.optJSONArray("rejected")?.let { a -> (0 until a.length()).map { a.getInt(it) }.toSet() } ?: emptySet(),
        )
    }
}

/** A person in a [FaceLibrary]. */
data class Person(
    val id: Int,
    val name: String?,
    /** Their faces' ids, the clearest first. */
    val faces: List<String>,
    val photoCount: Int,
) {
    /** The face to show for them: their clearest. */
    val keyFace: String get() = faces[0]
}

/** Which faces [Face.faces] and [FaceDetector.faces] keep. */
data class Options(
    /** Faces the detector scores lower are left out. [Face] defaults to 0.35 ([RECOGNITION]), [FaceDetector] to 0.3. */
    val minimumConfidence: Double = 0.3,
    /** Face leaves out faces smaller than this many pixels on their shorter side. */
    val minimumSize: Int = 32,
    /** At most this many faces, the most confident first. */
    val maxFaces: Int = 20,
) {
    companion object {
        /** [Face]'s default: faces scoring 0.35 or more, so fewer statues, cartoons and animals reach a [FaceLibrary]. */
        @JvmField val RECOGNITION = Options(minimumConfidence = 0.35)
    }
}

/** Thrown when the model cannot be created, loaded, or run. */
class FaceException(message: String) : Exception(message)

/**
 * On-device face matching. Create one `Face` and reuse it; the model loads on the
 * first [faces] call (or eagerly with [download]).
 *
 * ```kotlin
 * Face(context).use { face ->
 *     val library = face.library()
 *     library.add(face.faces(bitmap), photo = "IMG_0001")
 *     val people = library.people()
 * }
 * ```
 *
 * For where the faces are without faceprints, [FaceDetector] downloads the detector alone.
 *
 * @param directory the folder for the model's files. Face uses files already there,
 *   and otherwise downloads the model into the folder. Omit to use the app cache,
 *   where [FaceDetector] and Eye find the same detector.
 */
class Face @JvmOverloads constructor(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model = LoadedModel(MODEL_ID, MODEL_NAME, context, directory, ::FaceException, FaceNative)

    /** Whether the model is available with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /** Download the model ahead of time so the first [faces] is instant. */
    suspend fun download() = model.download()

    /** The faces in a [Bitmap], upright, most confident first. */
    suspend fun faces(bitmap: Bitmap, options: Options = Options.RECOGNITION): List<DetectedFace> =
        faces(bitmap.rgb(), bitmap.width, bitmap.height, options)

    /** The faces in raw pixels: `width * height` RGB or RGBA bytes, row-major from the top left, upright. */
    suspend fun faces(pixels: ByteArray, width: Int, height: Int, options: Options = Options.RECOGNITION): List<DetectedFace> {
        val answer = model.faces(pixels, width, height, options)
        return (0 until answer.length()).map { answer.getJSONObject(it).toDetectedFace() }
    }

    /** A new library, or one you saved ([FaceLibrary.save]) or built from your own rows. */
    @JvmOverloads
    suspend fun library(saved: JSONObject? = null): FaceLibrary {
        val opened = call("library.open", JSONObject().apply { saved?.let { put("library", it) } }) as JSONObject
        return FaceLibrary(this, opened.getInt("handle"))
    }

    /** A library from your own rows: face records and the names the user gave. */
    suspend fun library(faces: List<FaceRecord>, names: Map<Int, String> = emptyMap()): FaceLibrary =
        library(JSONObject().put("faces", JSONArray(faces.map { it.toJson() }))
            .put("names", JSONObject(names.mapKeys { it.key.toString() })))

    internal suspend fun call(op: String, args: JSONObject, input: ByteArray = ByteArray(0)): Any? = model.call(op, args, input)

    /** Release the native model. Calling this again is a no-op. */
    @Synchronized override fun close() = model.close()

    companion object {
        /** Every faceprint matching [reference], most similar first: (index, similarity). */
        @JvmStatic @JvmOverloads
        fun matches(reference: Faceprint, faceprints: List<Faceprint>, level: Level = Level.RECOMMENDED): List<Pair<Int, Double>> =
            faceprints.mapIndexedNotNull { i, f ->
                if (!f.isComparable(reference)) null
                else reference.similarity(f).takeIf { it >= level.cutoff }?.let { i to it }
            }.sortedByDescending { it.second }
    }
}

/**
 * On-device face detection: where the faces in a photo are, with five landmarks
 * each, and no faceprints. Downloads Face's detector alone, which [Face] and Eye
 * share, so an app that also uses them downloads it once.
 *
 * ```kotlin
 * FaceDetector(context).use { detector ->
 *     for (face in detector.faces(bitmap)) blur(face.box)
 * }
 * ```
 *
 * @param directory the folder for the detector's files, which can be [Face]'s. Omit to use the app cache.
 */
class FaceDetector @JvmOverloads constructor(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model = LoadedModel("$MODEL_ID/detector", "FaceDetector", context, directory, ::FaceException, FaceNative)

    /** Whether the detector is available with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /** Download the detector ahead of time so the first [faces] is instant. */
    suspend fun download() = model.download()

    /** The faces in a [Bitmap], upright, most confident first. */
    suspend fun faces(bitmap: Bitmap, options: Options = Options()): List<FaceDetection> =
        faces(bitmap.rgb(), bitmap.width, bitmap.height, options)

    /** The faces in raw pixels: `width * height` RGB or RGBA bytes, row-major from the top left, upright. */
    suspend fun faces(pixels: ByteArray, width: Int, height: Int, options: Options = Options()): List<FaceDetection> {
        val answer = model.faces(pixels, width, height, options)
        return (0 until answer.length()).map { answer.getJSONObject(it).toDetection() }
    }

    /** Release the native detector. Calling this again is a no-op. */
    @Synchronized override fun close() = model.close()
}

/**
 * The people in a set of photos, for a people view where the user sees, names and
 * fixes faces. Get one from [Face.library]. The library runs in the SDK's Swift
 * core, so every platform groups faces the same way.
 */
class FaceLibrary internal constructor(private val face: Face, private var handle: Int?) {
    private suspend fun call(op: String, args: JSONObject = JSONObject()): Any? {
        val h = handle ?: throw FaceException("this library is closed")
        return face.call("library.$op", args.put("handle", h))
    }

    /** Add a photo's faces (from [Face.faces]), replacing any it had. Their ids are `"<photo>#<index>"`. */
    @JvmOverloads
    suspend fun add(faces: List<DetectedFace>, photo: String, date: Date? = null) {
        call("add", JSONObject().put("faces", JSONArray(faces.map { it.toJson() })).put("photo", photo).putDate(date))
    }

    /** Add one face with your own id. */
    @JvmOverloads
    suspend fun add(face: DetectedFace, id: String, photo: String, date: Date? = null) {
        call("addFace", JSONObject().put("face", face.toJson()).put("id", id).put("photo", photo).putDate(date))
    }

    /** Remove a photo and its faces. */
    suspend fun removePhoto(photo: String) { call("removePhoto", JSONObject().put("photo", photo)) }

    /** Remove one face. */
    suspend fun removeFace(id: String) { call("removeFace", JSONObject().put("id", id)) }

    /** The people, most photographed first. [prominent] lists the ones that matter to the user. */
    @JvmOverloads
    suspend fun people(prominent: Boolean = false): List<Person> =
        (call("people", JSONObject().put("prominent", prominent)) as JSONArray).let { a ->
            (0 until a.length()).map { a.getJSONObject(it).toPerson() }
        }

    /** A person by id. */
    suspend fun person(id: Int): Person? = (call("person", JSONObject().put("person", id)) as? JSONObject)?.toPerson()

    /** Who this faceprint is, if it clearly matches someone. */
    suspend fun person(faceprint: Faceprint): Person? =
        (call("personFor", JSONObject().put("faceprint", faceprint.toJson())) as? JSONObject)?.toPerson()

    /** A face record by id. */
    suspend fun face(id: String): FaceRecord? = (call("face", JSONObject().put("id", id)) as? JSONObject)?.let(FaceRecord::fromJson)

    /** Faces that may be this person, most likely first: for "Is this also Noor?". */
    @JvmOverloads
    suspend fun suggestions(person: Int, limit: Int = 20): List<String> =
        (call("suggestions", JSONObject().put("person", person).put("limit", limit)) as JSONArray).let { a ->
            (0 until a.length()).map { a.getString(it) }
        }

    /** The face records whose person, confirmation or rejections changed since the last call. */
    suspend fun takeChanges(): List<FaceRecord> =
        (call("takeChanges") as JSONArray).let { a -> (0 until a.length()).map { FaceRecord.fromJson(a.getJSONObject(it)) } }

    /** The names the user gave, by person id. */
    suspend fun names(): Map<Int, String> =
        (call("names") as JSONObject).let { o -> o.keys().asSequence().associate { it.toInt() to o.getString(it) } }

    /** Name a person, or clear the name with `null`. */
    suspend fun name(person: Int, name: String?) {
        call("name", JSONObject().put("person", person).apply { name?.let { put("name", it) } })
    }

    /** "This is Noor". */
    suspend fun confirm(id: String, person: Int) { call("confirm", JSONObject().put("id", id).put("person", person)) }

    /** "This is not Noor". */
    suspend fun reject(id: String, person: Int) { call("reject", JSONObject().put("id", id).put("person", person)) }

    /** "This is Ana", someone new: returns her id, or `null` if there is no such face. */
    suspend fun newPerson(id: String, name: String): Int? =
        (call("newPerson", JSONObject().put("id", id).put("name", name)) as? Number)?.toInt()

    /** "These are the same person": move every face of [other] to [person]. */
    suspend fun merge(other: Int, person: Int) { call("merge", JSONObject().put("other", other).put("person", person)) }

    /** Regroup every face now, keeping what the user said. */
    suspend fun regroup() { call("regroup") }

    /** The whole library as portable JSON: store it, or pass it to [Face.library]. */
    suspend fun save(): JSONObject = call("save") as JSONObject

    /** Release the library. */
    suspend fun close() {
        if (handle == null) return
        call("close")
        handle = null
    }
}

private fun JSONObject.putDate(date: Date?): JSONObject = apply { date?.let { put("date", it.time / 1000.0) } }

private fun Box.toJson() = JSONObject().put("x0", x0).put("y0", y0).put("x1", x1).put("y1", y1)

private fun JSONObject.toBox() = Box(getDouble("x0"), getDouble("y0"), getDouble("x1"), getDouble("y1"))

private fun DetectedFace.toJson() = JSONObject()
    .put("box", box.toJson())
    .put("landmarks", JSONArray(landmarks.map { JSONObject().put("x", it.x).put("y", it.y) }))
    .put("confidence", confidence)
    .put("faceprint", faceprint.toJson())

private fun JSONObject.toDetection(): FaceDetection {
    val lm = getJSONArray("landmarks")
    return FaceDetection(
        getJSONObject("box").toBox(),
        (0 until lm.length()).map { lm.getJSONObject(it).let { p -> Point(p.getDouble("x"), p.getDouble("y")) } },
        getDouble("confidence"),
    )
}

private fun JSONObject.toDetectedFace(): DetectedFace =
    toDetection().let { DetectedFace(it.box, it.landmarks, it.confidence, Faceprint.fromJson(getJSONObject("faceprint"))) }

private fun Bitmap.rgb(): ByteArray {
    val source = if (config == Bitmap.Config.ARGB_8888) this
        else copy(Bitmap.Config.ARGB_8888, false) ?: throw FaceException("the bitmap could not be read")
    val argb = IntArray(width * height)
    source.getPixels(argb, 0, width, 0, 0, width, height)
    if (source !== this) source.recycle()
    val rgb = ByteArray(argb.size * 3)
    for (i in argb.indices) {
        val c = argb[i]
        rgb[i * 3] = (c shr 16).toByte()
        rgb[i * 3 + 1] = (c shr 8).toByte()
        rgb[i * 3 + 2] = c.toByte()
    }
    return rgb
}

/** One operation of the binding (Sources/Face/SDK/Binding.swift), its answer parsed. */
private suspend fun LoadedModel.call(op: String, args: JSONObject, input: ByteArray = ByteArray(0)): Any? {
    val options = FfiWriter().string(op).string(args.toString()).done()
    val text = run(input, options, failureMessage = "$op failed") { it.string() }
    return if (text == "null") null else org.json.JSONTokener(text).nextValue()
}

private suspend fun LoadedModel.faces(pixels: ByteArray, width: Int, height: Int, options: Options): JSONArray {
    val channels = if (width > 0 && height > 0) pixels.size / (width * height) else 0
    require((channels == 3 || channels == 4) && pixels.size == width * height * channels) {
        "pixels must hold ${width}x$height RGB or RGBA bytes, got ${pixels.size}"
    }
    val input = FfiWriter().int(width).int(height).int(channels).blob(pixels).done()
    val args = JSONObject().put("minimumConfidence", options.minimumConfidence)
        .put("minimumSize", options.minimumSize).put("maxFaces", options.maxFaces)
    return call("faces", args, input) as JSONArray
}

private fun JSONObject.toPerson(): Person {
    val f = getJSONArray("faces")
    return Person(getInt("id"), if (has("name") && !isNull("name")) getString("name") else null,
        (0 until f.length()).map { f.getString(it) }, getInt("photoCount"))
}
