package ai.desertant.eye

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min

/**
 * Something Eye can say about a photo or a face: `Tags.SCREENSHOT`, `Tags.DOG`, `Tags.BLURRY`, `Tags.GROUP_SHOT`, ...
 * Every tag has a confidence in `0..1` where 0.5 is the recommended cutoff and 0.9 a strict one, the same for every tag.
 */
data class Tag(val id: String) {
    override fun toString() = id
}

/** How sure a tag must be: the cutoff on its confidence. */
enum class Level(val cutoff: Double) {
    /** The balance of precision and recall Eye recommends. */
    RECOMMENDED(0.5),
    /** High precision: fewer photos, more surely right. */
    STRICT(0.9),
}

/** Percentiles in `0..1` against the calibration set (0.5 is the median photo). */
data class Scores(
    /** How good the photo is as a photograph. */
    val aesthetic: Double,
    /** How likely people are to keep a photo like this. */
    val keeper: Double,
    /** How well it would work as a cover or thumbnail. */
    val cover: Double,
)

/** One face in the photo, with its tags (`Tags.EYES_CLOSED`, `Tags.SMILING`, `Tags.LOOKING_AT_CAMERA`, ...). */
data class Face(
    val box: Box,
    /** How sure the detector is that this is a face, `0..1`. */
    val detectionConfidence: Double,
    /** Left eye, right eye, nose tip, left and right mouth corners. */
    val landmarks: List<Point>,
    val pose: Pose,
    /** Overall quality of the face in this photo, `0..1`. */
    val quality: Double,
    val confidences: Map<Tag, Double>,
) {
    fun confidence(tag: Tag): Double? = confidences[tag]

    @JvmOverloads
    fun has(tag: Tag, level: Level = Level.RECOMMENDED): Boolean = (confidences[tag] ?: 0.0) >= level.cutoff
}

/**
 * What Eye found in one photo: tags with confidences, scores, people, pets, faces, a crop, a rotation fix and an
 * embedding. Filter with [has], rank with [confidence] or [scores]. Everything except [details] round-trips through
 * [toJson] (the same JSON as the Swift and JavaScript SDKs), so analyses can be stored and filtered later without the model.
 */
class Analysis internal constructor(
    /** The model that produced it (`"eye@v1.0.0"`). */
    val model: String,
    val width: Int,
    val height: Int,
    /** Every tag computed, with its confidence. A tag whose part was not computed is absent. */
    val confidences: Map<Tag, Double>,
    /** The most likely photo type: `Tags.PHOTO`, `Tags.SELFIE`, `Tags.SCREENSHOT`, ... */
    val kind: Tag?,
    val scores: Scores?,
    /**
     * How far the photo is turned clockwise from upright (90, 180 or 270), so turning it back counterclockwise by
     * this much makes it upright. Null when it is upright or Eye is unsure.
     */
    val rotation: Int?,
    /** 512 numbers, unit length; see [similarity]. */
    val embedding: FloatArray?,
    val people: List<Detection>?,
    /** Cats and dogs. */
    val pets: List<Detection>?,
    val faces: List<Face>?,
    /** The best crops, best first; see [bestCrop]. */
    val crops: List<Crop>?,
    /** The model's raw outputs; null for an analysis restored from JSON. */
    val details: Details?,
    private val json: JSONObject,
) {
    fun confidence(tag: Tag): Double? = confidences[tag]

    /** Whether [tag] reaches [level] (0.5 recommended, 0.9 strict). */
    @JvmOverloads
    fun has(tag: Tag, level: Level = Level.RECOMMENDED): Boolean = (confidences[tag] ?: 0.0) >= level.cutoff

    /** The tags at or above [level], most confident first. */
    @JvmOverloads
    fun tags(level: Level = Level.RECOMMENDED): List<Tag> =
        confidences.filter { it.value >= level.cutoff }.entries.sortedWith(compareBy({ -it.value }, { it.key.id })).map { it.key }

    /** The best crop with this width-to-height ratio (1 square, 16/9 a banner), in `0..1` of the image. */
    fun bestCrop(aspect: Double): Box? {
        val crops = crops ?: return null
        val best = crops.firstOrNull() ?: return null
        if (aspect <= 0) return null
        val px = { b: Box -> b.width * width / max(b.height * height, 1e-9) }
        crops.firstOrNull { abs(ln(px(it.box) / aspect)) <= ln(1.1) }?.let { return it.box }
        var w = best.box.width
        var h = best.box.height
        val target = aspect * height / width
        if (w / h > target) w = h * target else h = w / target
        if (w > 1) { h /= w; w = 1.0 }
        if (h > 1) { w /= h; h = 1.0 }
        val cx = min(max((best.box.x0 + best.box.x1) / 2, w / 2), 1 - w / 2)
        val cy = min(max((best.box.y0 + best.box.y1) / 2, h / 2), 1 - h / 2)
        return Box(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)
    }

    /** Cosine similarity of the two embeddings, `-1..1`; near-duplicates are above about 0.9. */
    fun similarity(other: Analysis): Double? {
        val a = embedding ?: return null
        val b = other.embedding ?: return null
        if (a.size != b.size) return null
        var s = 0f
        for (i in a.indices) s += a[i] * b[i]
        return s.toDouble()
    }

    /** The analysis as JSON (without [details]), for storage; [fromJson] reads it back. */
    fun toJson(): String = json.toString()

    internal val duplicates: JSONObject? get() = json.optJSONObject("duplicates")

    companion object {
        /** An analysis stored with [toJson] (or by the Swift or JavaScript SDK). */
        @JvmStatic
        fun fromJson(json: String): Analysis = fromJson(JSONObject(json), null)

        internal fun fromJson(o: JSONObject, details: Details?): Analysis {
            fun box(a: JSONObject) = Box(a.getDouble("x0"), a.getDouble("y0"), a.getDouble("x1"), a.getDouble("y1"))
            fun tags(t: JSONObject): Map<Tag, Double> = t.keys().asSequence().associate { Tag(it) to t.getDouble(it) }
            fun <T> list(key: String, f: (JSONObject) -> T): List<T>? =
                o.optJSONArray(key)?.let { a -> List(a.length()) { f(a.getJSONObject(it)) } }
            fun detection(d: JSONObject) = Detection(d.getString("label"), d.getDouble("confidence"), box(d.getJSONObject("box")))
            val scores = o.optJSONObject("scores")?.let { Scores(it.getDouble("aesthetic"), it.getDouble("keeper"), it.getDouble("cover")) }
            val embedding = o.optJSONArray("embedding")?.let { a -> FloatArray(a.length()) { a.getDouble(it).toFloat() } }
            return Analysis(
                model = o.getString("model"),
                width = o.getInt("width"),
                height = o.getInt("height"),
                confidences = tags(o.getJSONObject("tags")),
                kind = if (o.has("kind")) Tag(o.getString("kind")) else null,
                scores = scores,
                rotation = if (o.has("rotation") && !o.isNull("rotation")) o.getInt("rotation") else null,
                embedding = embedding,
                people = list("people", ::detection),
                pets = list("pets", ::detection),
                faces = list("faces") { f ->
                    val lm = f.getJSONArray("landmarks")
                    val pose = f.getJSONObject("pose")
                    Face(box(f.getJSONObject("box")), f.getDouble("detection_confidence"),
                        List(lm.length()) { Point(lm.getJSONObject(it).getDouble("x"), lm.getJSONObject(it).getDouble("y")) },
                        Pose(pose.getDouble("yaw"), pose.getDouble("pitch"), pose.getDouble("roll")),
                        f.getDouble("quality"), tags(f.getJSONObject("tags")))
                },
                crops = list("crops") { Crop(box(it.getJSONObject("box")), it.getDouble("score")) },
                details = details,
                json = o,
            )
        }
    }
}

/** Near-duplicates, the best of a set, similar photos: pure functions over analyses (stored ones too). */
internal object Collections {
    fun duplicates(analyses: List<Analysis>, dates: List<Double?>?): List<List<Int>> {
        val n = analyses.size
        val parent = IntArray(n) { it }
        fun root(i: Int): Int {
            var x = i
            while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        val order = if (dates != null) (0 until n).filter { it < dates.size && dates[it] != null }.sortedBy { dates[it]!! }
            else (0 until n).toList()
        for ((k, i) in order.withIndex()) {
            val rule = analyses[i].duplicates ?: continue
            if (analyses[i].embedding == null) continue
            val similarity = rule.getDouble("similarity")
            val window = rule.getDouble("window_seconds")
            val windowPeople = rule.getDouble("window_seconds_people")
            for (j in order.subList(k + 1, order.size)) {
                if (dates != null) {
                    val dt = dates[j]!! - dates[i]!!
                    if (dt > max(window, windowPeople)) break
                    val people = analyses[i].has(Tags.PEOPLE) || analyses[j].has(Tags.PEOPLE)
                    if (dt > (if (people) windowPeople else window)) continue
                }
                val s = analyses[i].similarity(analyses[j]) ?: continue
                if (s >= similarity) parent[root(j)] = root(i)
            }
        }
        val groups = LinkedHashMap<Int, MutableList<Int>>()
        for (i in 0 until n) if (analyses[i].embedding != null) groups.getOrPut(root(i)) { mutableListOf() }.add(i)
        return groups.values.filter { it.size > 1 }
            .map { g -> g.sortedWith { a, b -> compare(rank(analyses[b]), rank(analyses[a])) } }
            .sortedBy { it[0] }
    }

    fun best(analyses: List<Analysis>): Int? = analyses.indices.maxWithOrNull { a, b -> compare(rank(analyses[a]), rank(analyses[b])) }

    fun similar(photo: Analysis, analyses: List<Analysis>, limit: Int): List<Pair<Int, Double>> =
        analyses.indices.mapNotNull { i -> photo.similarity(analyses[i])?.let { i to it } }
            .sortedByDescending { it.second }.take(max(0, limit))

    /** No closed eyes, then face quality to a tenth, then keeper (as the Swift SDK). */
    private fun rank(a: Analysis): DoubleArray {
        val faces = (a.faces ?: emptyList()).filter { it.detectionConfidence >= 0.5 }
        val area = faces.sumOf { it.box.width * it.box.height }
        val quality = if (faces.isEmpty()) 0.5 else faces.sumOf { it.quality * it.box.width * it.box.height } / max(area, 1e-9)
        return doubleArrayOf(if (a.has(Tags.EYES_CLOSED)) 0.0 else 1.0, Math.round(quality * 10) / 10.0, a.scores?.keeper ?: 0.0)
    }

    private fun compare(a: DoubleArray, b: DoubleArray): Int {
        for (i in a.indices) if (a[i] != b[i]) return a[i].compareTo(b[i])
        return 0
    }
}
