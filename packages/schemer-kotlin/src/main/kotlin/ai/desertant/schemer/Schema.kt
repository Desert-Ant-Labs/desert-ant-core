package ai.desertant.schemer

/**
 * One field to extract.
 *
 * The schema is an *input*, not something baked into the weights: the model is
 * schema-generic, so a new schema is a runtime value and needs no retraining.
 */
sealed class Field {
    abstract val name: String

    /**
     * A short natural-language hint. Read by the model, not ignored: it
     * conditions the encoding, so it is worth writing well ("the shop or
     * vendor" beats "merchant name").
     */
    abstract val describe: String?

    /**
     * Whether absence is an expected answer. Set to true, a number may come
     * back [Value.Absent] (otherwise it composes a value), and the number and
     * datetime heads are told absence is expected, which moves their
     * decisions: so setting it is not the same as leaving it null.
     */
    abstract val nullable: Boolean?

    /** A verbatim span of the input. */
    data class Text(
        override val name: String,
        override val describe: String? = null,
        override val nullable: Boolean? = null,
    ) : Field()

    /**
     * A number located in the text and parsed by the harness. [min] and [max]
     * are an inclusive range (a value outside it is clamped) and, with [unit]
     * ("currency", "kg", "hour"), are read by the number head.
     */
    data class Number(
        override val name: String,
        override val describe: String? = null,
        override val nullable: Boolean? = null,
        val min: Double? = null,
        val max: Double? = null,
        val unit: String? = null,
    ) : Field()

    /** Three-way: absent, false, or true. */
    data class Bool(
        override val name: String,
        override val describe: String? = null,
        override val nullable: Boolean? = null,
    ) : Field()

    /** Resolved to ISO-8601, relative dates included. */
    data class DateTime(
        override val name: String,
        override val describe: String? = null,
        override val nullable: Boolean? = null,
    ) : Field()

    /** One of [values], chosen by meaning rather than by exact match. */
    data class Label(
        override val name: String,
        val values: List<String>,
        override val describe: String? = null,
        override val nullable: Boolean? = null,
    ) : Field()

    /** Zero or more verbatim spans. */
    data class TextList(
        override val name: String,
        override val describe: String? = null,
        override val nullable: Boolean? = null,
    ) : Field()

    /**
     * Zero or more objects with these [properties]: "the order lines", "the
     * stops of a trip". The text is split into candidate items and the
     * properties are extracted from each, so it works where each item has its
     * own clause or list entry. Properties cannot themselves be [Objects].
     */
    data class Objects(
        override val name: String,
        val properties: List<Field>,
        override val describe: String? = null,
        override val nullable: Boolean? = null,
    ) : Field()

    /** Wire tag, in the order Sources/Schemer/Binding.swift reads. */
    internal val typeTag: Int
        get() = when (this) {
            is Text -> 0
            is Number -> 1
            is Bool -> 2
            is DateTime -> 3
            is Label -> 4
            is TextList -> 5
            is Objects -> 6
        }
}

/**
 * One extracted value.
 *
 * [Absent] is a real answer: it means the text did not state the field, which
 * is the case the model is built to detect. It is a distinct case rather than
 * a Kotlin `null` so that `when` over a result is exhaustive.
 */
sealed class Value {
    object Absent : Value()
    data class Text(val value: String) : Value()
    data class Number(val value: Double) : Value()
    data class Bool(val value: Boolean) : Value()

    /** ISO-8601, `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM`. */
    data class DateTime(val iso: String) : Value()
    data class Label(val value: String) : Value()
    data class TextList(val values: List<String>) : Value()

    /**
     * The items of an [Field.Objects] field, in the order the text lists them.
     * Each holds only the properties the text states, in schema order.
     */
    data class Objects(val items: List<Map<String, Value>>) : Value()

    /** The value as a Kotlin type, or null when absent. */
    fun orNull(): Any? = when (this) {
        is Absent -> null
        is Text -> value
        is Number -> value
        is Bool -> value
        is DateTime -> iso
        is Label -> value
        is TextList -> values
        is Objects -> items.map { item -> item.mapValues { it.value.orNull() } }
    }
}

/** Field name to value, in schema order. */
class Extraction internal constructor(
    private val ordered: List<Pair<String, Value>>,
    /**
     * Whether the text was longer than the model reads (about 1,216 tokens
     * with the schema), so its end was never seen. Values stated only past
     * that point come back absent.
     */
    val truncated: Boolean = false,
) {
    operator fun get(name: String): Value =
        ordered.firstOrNull { it.first == name }?.second ?: Value.Absent

    fun toMap(): Map<String, Value> = ordered.toMap()

    /** Field name to plain Kotlin value, absent fields as null. */
    fun toAnyMap(): Map<String, Any?> = ordered.associate { it.first to it.second.orNull() }

    val fields: List<String> get() = ordered.map { it.first }
}
