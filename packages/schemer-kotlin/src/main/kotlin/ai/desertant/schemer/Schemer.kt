package ai.desertant.schemer

import ai.desertant.core.FfiReader
import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel
import java.util.Date

/** The catalog id, which is how the shared native layer is asked for Schemer. */
private const val MODEL_ID = "schemer"
private const val MODEL_NAME = "Schemer"

/** The compiled label graph takes a fixed candidate count. */
const val MAX_LABEL_VALUES = 16

/** Thrown when the model cannot be created, loaded, or run, or the schema is
 *  one the runtime cannot honor. */
class SchemerException(message: String) : Exception(message)

/**
 * On-device structured extraction: free text plus a schema you define, and
 * typed values back. Mirrors the iOS/Swift SDK: create one `Schemer` and reuse
 * it; the model loads lazily on the first [extract] (or eagerly via
 * [download]).
 *
 * ```kotlin
 * val schemer = Schemer(context)
 * val out = schemer.extract(
 *     "Coffee meeting at Blue Bottle, \$18.50, reimbursable.",
 *     listOf(
 *         Field.Text("merchant", describe = "the shop or vendor"),
 *         Field.Number("amount", describe = "total paid"),
 *         Field.Bool("reimbursable"),
 *     ),
 * )
 * out["amount"]            // Value.Number(18.5)
 * out.toAnyMap()           // {merchant=Blue Bottle, amount=18.5, reimbursable=true}
 * schemer.close()
 * ```
 *
 * Nothing is generated. Every field is decoded by a head built for its type,
 * so the result is typed by construction: extracted strings are always
 * substrings of the input, labels are always one of the values you declared,
 * and a field the text does not state comes back [Value.Absent] rather than
 * invented.
 *
 * Creating, downloading, running, and releasing the model are the shared
 * `ai.desertant:core` shell ([LoadedModel]); what lives here is Schemer's API
 * and its payload schemas.
 *
 * @param directory the model's home. Files already there are adopted (so an
 *   app that ships the model just points at the folder it unpacked it into),
 *   otherwise the model is downloaded into it. Omit to use the app cache.
 */
class Schemer(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model =
        LoadedModel(MODEL_ID, MODEL_NAME, context, directory, ::SchemerException, SchemerNative)

    companion object {
        /**
         * Reject a schema the runtime cannot honor, with the same
         * [SchemerException] [extract] would throw. It needs no model, so an
         * app can check a schema before downloading one.
         */
        @JvmStatic
        fun validate(schema: List<Field>) = validateSchema(schema)
    }

    /** Whether the model is available with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /**
     * Download the model ahead of time so the first [extract] is instant. A
     * no-op once available (see [isDownloaded]). Suspends on a background
     * dispatcher.
     */
    suspend fun download() = model.download()

    /**
     * Extract every field in [schema] from [text]. Loads the model lazily on
     * first call.
     *
     * @param now the date relative expressions ("tomorrow at 9:30") resolve
     *   against, read as a day in the device's time zone. Defaults to the
     *   device clock; pass a fixed date for
     *   reproducible results. The model never learns date arithmetic: the
     *   runtime hands it `today=YYYY-MM-DD` and the datetime head decodes an
     *   offset from it.
     */
    suspend fun extract(text: String, schema: List<Field>, now: Date? = null): Extraction {
        validateSchema(schema)
        if (schema.isEmpty()) return Extraction(emptyList())

        // Input payload: the text, the field count, then each field. Options
        // payload: the anchor string, always written here because the native
        // side may not know the device's time zone. Result payload: a field
        // count, each value's kind and body, then the truncated flag. All
        // three must match Sources/Schemer/Binding.swift.
        val opts = FfiWriter().string(anchorString(now ?: Date())).done()
        return model.run(encodeInput(text, schema), opts, failureMessage = "extraction failed") { r ->
            decodeExtraction(r, schema)
        }
    }

    /** Release the native model. The extractor is unusable afterwards; calling
     *  this again is a no-op. */
    @Synchronized override fun close() = model.close()
}

/**
 * Input payload: the text, the field count, then each field. Must match
 * Sources/Schemer/Binding.swift, and does byte for byte: the instrumented suite
 * checks it against Tests/SchemerTests/Resources/schemer_wire.input, which the
 * JS encoder wrote and the Swift reader decodes.
 */
internal fun encodeInput(text: String, schema: List<Field>): ByteArray =
    encodeFields(FfiWriter().string(text), schema).done()

private fun encodeFields(input: FfiWriter, schema: List<Field>): FfiWriter {
    input.int(schema.size)
    for (f in schema) {
        // nullable is three-way on the wire: 0 false, 1 true, 2 not stated.
        input.string(f.name).int(f.typeTag).string(f.describe ?: "")
            .int(when (f.nullable) { false -> 0; true -> 1; null -> 2 })
        if (f is Field.Label) {
            input.int(f.values.size)
            for (v in f.values) input.string(v)
        }
        if (f is Field.Number) {
            input.int(if (f.min != null) 1 else 0).double(f.min ?: 0.0)
                .int(if (f.max != null) 1 else 0).double(f.max ?: 0.0)
                .string(f.unit ?: "")
        }
        if (f is Field.Objects) encodeFields(input, f.properties)
    }
    return input
}

/** Reject what the runtime cannot honor, before any model runs. */
private fun validateSchema(schema: List<Field>, nested: Boolean = false) {
    val seen = mutableSetOf<String>()
    for (f in schema) {
        if (f is Field.Objects) {
            if (nested) {
                throw SchemerException(
                    "field '${f.name}' nests objects inside objects, which is not supported")
            }
            validateSchema(f.properties, nested = true)
        }
        if (f.name.isEmpty()) throw SchemerException("a field has an empty name")
        if (!seen.add(f.name)) throw SchemerException("duplicate field name '${f.name}'")
        if (f is Field.Number && (f.min?.isFinite() == false || f.max?.isFinite() == false)) {
            throw SchemerException("number field '${f.name}' has a non-finite bound")
        }
        if (f is Field.Number && f.min != null && f.max != null && f.min > f.max) {
            throw SchemerException("number field '${f.name}' has min ${f.min} above max ${f.max}")
        }
        if (f is Field.Label) {
            if (f.values.isEmpty()) {
                throw SchemerException("label field '${f.name}' has no values")
            }
            if (f.values.size > MAX_LABEL_VALUES) {
                throw SchemerException(
                    "label field '${f.name}' has ${f.values.size} values; the compiled " +
                        "label graph takes at most $MAX_LABEL_VALUES",
                )
            }
        }
    }
}

/** The day [date] falls on in the device's time zone: "yesterday" is the day
 *  before the user's today, which a UTC day misses around midnight. */
private fun anchorString(date: Date): String {
    val cal = java.util.Calendar.getInstance(java.util.TimeZone.getDefault())
    cal.time = date
    // Locale.US: the anchor is a wire value, and a locale with its own digits
    // would write numerals Schemer.date(fromAnchor:) cannot parse.
    return String.format(
        java.util.Locale.US,
        "today=%04d-%02d-%02d",
        cal.get(java.util.Calendar.YEAR),
        cal.get(java.util.Calendar.MONTH) + 1,
        cal.get(java.util.Calendar.DAY_OF_MONTH),
    )
}

/** Decode the result payload Sources/Schemer/Binding.swift writes. */
private fun decodeExtraction(r: FfiReader, schema: List<Field>): Extraction {
    val count = r.int()
    val out = ArrayList<Pair<String, Value>>(count)
    for (i in 0 until count) {
        val name = schema.getOrNull(i)?.name ?: "field$i"
        // A kind this SDK does not know is a core newer than the AAR. Report
        // the field as absent rather than half-decoding the rest.
        val value = decodeValue(r) ?: return Extraction(out + (name to Value.Absent))
        out.add(name to value)
    }
    return Extraction(out, truncated = r.hasRemaining() && r.int() != 0)
}

private fun decodeValue(r: FfiReader): Value? {
    return when (r.int()) {
        0 -> Value.Absent
        1 -> Value.Text(r.string())
        2 -> Value.Number(r.double())
        3 -> Value.Bool(r.int() != 0)
        4 -> Value.DateTime(r.string())
        5 -> Value.Label(r.string())
        6 -> Value.TextList(List(r.int()) { r.string() })
        7 -> {
            val items = ArrayList<Map<String, Value>>()
            repeat(r.int()) {
                val item = LinkedHashMap<String, Value>()
                repeat(r.int()) {
                    val key = r.string()
                    item[key] = decodeValue(r) ?: return null
                }
                items.add(item)
            }
            Value.Objects(items)
        }
        else -> null
    }
}
