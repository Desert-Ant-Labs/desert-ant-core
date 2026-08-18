package ai.desertant.tongue

import kotlin.math.exp

/**
 * The head. No inference runtime and none needed: a detection is an int8
 * embedding gather, a sum over the n-grams present, one small matmul and a masked
 * softmax — a few thousand multiply-adds.
 *
 * Byte layout of tongue_int8.bin, written by scripts/build_release.py:
 *
 *     [0]                   int8   embedding, numBuckets * dim, row-major
 *     [numBuckets*dim]      fp32   linear weight, labels * dim, row-major
 *     [+ labels*dim*4]      fp32   linear bias, labels
 *
 * fp32 fields are little-endian.
 */
internal class Metadata(
    val labels: List<String>,
    val numBuckets: Int,
    val dimension: Int,
    val ngramOrders: List<Int>,
    val embeddingScale: Float,
    val latinLabels: List<String>,
) {
    companion object {
        /**
         * Minimal reader for the flat metadata document.
         *
         * Hand-rolled rather than pulling in a JSON library: this artifact should
         * add no transitive dependency to an Android app, and the document is a
         * flat object of string arrays, ints and one float, written by our own
         * build. Anything unexpected raises rather than silently defaulting.
         */
        fun parse(json: String): Metadata {
            fun strings(key: String): List<String>? =
                Regex("\"$key\"\\s*:\\s*\\[(.*?)]", RegexOption.DOT_MATCHES_ALL)
                    .find(json)?.groupValues?.get(1)
                    ?.let { body ->
                        Regex("\"(.*?)\"").findAll(body).map { it.groupValues[1] }.toList()
                    }
            fun ints(key: String): List<Int>? =
                Regex("\"$key\"\\s*:\\s*\\[(.*?)]", RegexOption.DOT_MATCHES_ALL)
                    .find(json)?.groupValues?.get(1)
                    ?.let { body -> Regex("-?\\d+").findAll(body).map { it.value.toInt() }.toList() }
            fun number(key: String): Double? =
                Regex("\"$key\"\\s*:\\s*(-?[0-9.eE+]+)").find(json)?.groupValues?.get(1)?.toDoubleOrNull()

            val labels = strings("labels")
                ?: throw TongueException("tongue_meta.json: missing or malformed 'labels'")
            val numBuckets = number("num_buckets")?.toInt()
                ?: throw TongueException("tongue_meta.json: missing 'num_buckets'")
            val dimension = number("dim")?.toInt()
                ?: throw TongueException("tongue_meta.json: missing 'dim'")
            val orders = ints("ngram_orders") ?: Hashing.NGRAM_ORDERS
            val scale = number("embed_scale")?.toFloat()
                ?: throw TongueException("tongue_meta.json: missing 'embed_scale'")
            // Absent in older metadata: fall back to every label so an older
            // weights/metadata pair stays loadable.
            val latin = strings("latin_labels") ?: labels
            return Metadata(labels, numBuckets, dimension, orders, scale, latin)
        }
    }
}

internal class Weights(bytes: ByteArray, private val metadata: Metadata) {
    private val embedding: ByteArray
    private val linearWeight: FloatArray
    private val linearBias: FloatArray

    init {
        val labelCount = metadata.labels.size
        val embeddingCount = metadata.numBuckets * metadata.dimension
        val weightCount = labelCount * metadata.dimension
        val expected = embeddingCount + (weightCount + labelCount) * 4
        if (bytes.size != expected) {
            throw TongueException(
                "weights file is ${bytes.size} bytes, expected $expected for this metadata"
            )
        }
        // int8 values are already signed bytes on the JVM, so the embedding table
        // needs no conversion — just a view of the prefix.
        embedding = bytes.copyOfRange(0, embeddingCount)
        var offset = embeddingCount
        linearWeight = FloatArray(weightCount) {
            val value = readFloat(bytes, offset); offset += 4; value
        }
        linearBias = FloatArray(labelCount) {
            val value = readFloat(bytes, offset); offset += 4; value
        }
    }

    /** Little-endian fp32, read by shifting so alignment never matters. */
    private fun readFloat(bytes: ByteArray, at: Int): Float {
        val bits = (bytes[at].toInt() and 0xFF) or
            ((bytes[at + 1].toInt() and 0xFF) shl 8) or
            ((bytes[at + 2].toInt() and 0xFF) shl 16) or
            ((bytes[at + 3].toInt() and 0xFF) shl 24)
        return Float.fromBits(bits)
    }

    /**
     * Top-[topK] languages for already-normalized text, decoded over [allowed].
     *
     * The mask is how the router composes with the head: Cyrillic input competes
     * among the Cyrillic labels, not all 59. Excluded labels get probability zero
     * and the remaining mass renormalizes over the candidates.
     */
    fun rank(text: String, allowed: Set<String>, topK: Int): List<Prediction> {
        val dimension = metadata.dimension
        val pooled = FloatArray(dimension)
        // Ascending bucket order: float addition is not associative, so the
        // accumulation order is part of the answer. All three ports sort, so they
        // pool identically. See the note in Sources/Tongue/Model.swift.
        for ((bucket, count) in Hashing.buckets(text, metadata.numBuckets, metadata.ngramOrders).toSortedMap()) {
            val base = bucket * dimension
            val weight = count * metadata.embeddingScale
            for (index in 0 until dimension) {
                pooled[index] += embedding[base + index] * weight
            }
        }

        val logits = ArrayList<Pair<String, Float>>(allowed.size)
        metadata.labels.forEachIndexed { labelIndex, label ->
            if (label !in allowed) return@forEachIndexed
            var sum = linearBias[labelIndex]
            val base = labelIndex * dimension
            for (index in 0 until dimension) sum += linearWeight[base + index] * pooled[index]
            logits.add(label to sum)
        }
        if (logits.isEmpty()) return emptyList()

        val maximum = logits.maxOf { it.second }
        val exponentiated = logits.map { it.first to exp((it.second - maximum).toDouble()) }
        val total = exponentiated.sumOf { it.second }
        return exponentiated
            .sortedByDescending { it.second }
            .take(topK)
            .map { Prediction(it.first, if (total > 0) it.second / total else 0.0) }
    }
}
