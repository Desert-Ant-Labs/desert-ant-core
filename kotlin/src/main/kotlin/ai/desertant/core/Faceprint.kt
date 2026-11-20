package ai.desertant.core

import android.util.Base64
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.sqrt

/**
 * One face's identity, from Face or from Eye with `faceprints`: 128 numbers of
 * unit length. Two faceprints of the same person point the same way. Store a faceprint as [data] (512 bytes) or [toJson],
 * and compare faceprints later without the model. Compare faceprints of one [model] only.
 */
class Faceprint private constructor(
    /** The values, unit length. */
    val values: FloatArray,
    /** The embedder that made the faceprint. */
    val model: String,
) {
    /** The values as 512 bytes, little-endian float32. */
    val data: ByteArray
        get() {
            val b = ByteBuffer.allocate(values.size * 4).order(ByteOrder.LITTLE_ENDIAN)
            values.forEach { b.putFloat(it) }
            return b.array()
        }

    /** Cosine similarity, `-1..1`. 0 for faceprints of different lengths, which come from different embedders. */
    fun similarity(other: Faceprint): Double {
        if (values.size != other.values.size) return 0.0
        var s = 0.0
        for (i in values.indices) s += values[i] * other.values[i]
        return s
    }

    /** Whether [other] is the same person at [level]. */
    @JvmOverloads
    fun isSamePerson(other: Faceprint, level: Level = Level.RECOMMENDED): Boolean =
        isComparable(other) && similarity(other) >= level.cutoff

    /** Whether [other] comes from the same embedder: the same model and length. */
    fun isComparable(other: Faceprint): Boolean = model == other.model && values.size == other.values.size

    /** `{"model": ..., "data": <base64>}`, the same on every platform. */
    fun toJson(): JSONObject = JSONObject().put("model", model).put("data", Base64.encodeToString(data, Base64.NO_WRAP))

    override fun equals(other: Any?): Boolean = other is Faceprint && model == other.model && values.contentEquals(other.values)
    override fun hashCode(): Int = 31 * model.hashCode() + values.contentHashCode()

    /** How sure a match must be. */
    enum class Level(
        /** The cosine similarity at or above which two faceprints are the same person. */
        val cutoff: Double,
    ) {
        /** One false match in 1,000 pairs of different people: albums, search, suggestions. */
        RECOMMENDED(0.4129),
        /** One false match in 10,000: anything that acts without asking. */
        STRICT(0.5116),
    }

    companion object {
        /** The embedder this SDK's faceprints come from. */
        const val MODEL = "face-1"

        /** A faceprint from values, scaled to unit length. */
        @JvmStatic @JvmOverloads
        fun of(values: FloatArray, model: String = MODEL): Faceprint {
            var n = 0.0
            for (v in values) n += v * v
            val norm = sqrt(n).toFloat()
            return Faceprint(if (norm > 0) FloatArray(values.size) { values[it] / norm } else values.copyOf(), model)
        }

        /** A faceprint from [data] and the [model] it was stored with. */
        @JvmStatic
        fun fromData(data: ByteArray, model: String): Faceprint {
            require(data.isNotEmpty() && data.size % 4 == 0) { "faceprint data must be whole float32 values" }
            val b = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
            return Faceprint(FloatArray(data.size / 4) { b.float }, model)
        }

        /** From [toJson]. */
        @JvmStatic
        fun fromJson(json: JSONObject): Faceprint =
            fromData(Base64.decode(json.getString("data"), Base64.NO_WRAP), json.getString("model"))

        /** One faceprint for a person seen in several photos: the direction of their mean. */
        @JvmStatic
        fun average(faceprints: List<Faceprint>): Faceprint? {
            val first = faceprints.firstOrNull() ?: return null
            if (faceprints.any { it.model != first.model || it.values.size != first.values.size }) return null
            val sum = FloatArray(first.values.size)
            for (f in faceprints) for (i in sum.indices) sum[i] += f.values[i]
            return of(sum, first.model)
        }
    }
}
