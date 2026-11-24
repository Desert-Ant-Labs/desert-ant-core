package ai.desertant.tongue.license

// Hand-rolled for the reason Metadata.parse is: the jar declares no dependency.
internal object Json {
    /** The document as a map when it is one JSON object, null for anything else. */
    fun parseObject(text: String): Map<String, Any?>? = try {
        @Suppress("UNCHECKED_CAST")
        Reader(text).document() as? Map<String, Any?>
    } catch (_: RuntimeException) {
        null
    }

    fun quote(text: String): String {
        val out = StringBuilder(text.length + 2).append('"')
        for (char in text) {
            when {
                char == '"' -> out.append("\\\"")
                char == '\\' -> out.append("\\\\")
                char < ' ' -> out.append("\\u").append(char.code.toString(16).padStart(4, '0'))
                else -> out.append(char)
            }
        }
        return out.append('"').toString()
    }

    private class Reader(private val text: String) {
        private var at = 0

        fun document(): Any? {
            val value = value(0)
            skipSpace()
            require(at == text.length)
            return value
        }

        private fun value(depth: Int): Any? {
            require(depth <= MAX_DEPTH)
            skipSpace()
            return when (text[at]) {
                '{' -> obj(depth)
                '[' -> array(depth)
                '"' -> string()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> number()
            }
        }

        private fun obj(depth: Int): Map<String, Any?> {
            val out = LinkedHashMap<String, Any?>()
            at++
            skipSpace()
            if (text[at] == '}') {
                at++
                return out
            }
            while (true) {
                skipSpace()
                val key = string()
                skipSpace()
                require(text[at++] == ':')
                out[key] = value(depth + 1)
                skipSpace()
                when (text[at++]) {
                    ',' -> continue
                    '}' -> return out
                    else -> throw IllegalArgumentException()
                }
            }
        }

        private fun array(depth: Int): List<Any?> {
            val out = ArrayList<Any?>()
            at++
            skipSpace()
            if (text[at] == ']') {
                at++
                return out
            }
            while (true) {
                out.add(value(depth + 1))
                skipSpace()
                when (text[at++]) {
                    ',' -> continue
                    ']' -> return out
                    else -> throw IllegalArgumentException()
                }
            }
        }

        private fun string(): String {
            require(text[at++] == '"')
            val out = StringBuilder()
            while (true) {
                val char = text[at++]
                when {
                    char == '"' -> return out.toString()
                    char == '\\' -> when (val escaped = text[at++]) {
                        '"', '\\', '/' -> out.append(escaped)
                        'b' -> out.append('\b')
                        'f' -> out.append('\u000C')
                        'n' -> out.append('\n')
                        'r' -> out.append('\r')
                        't' -> out.append('\t')
                        'u' -> {
                            out.append(text.substring(at, at + 4).toInt(16).toChar())
                            at += 4
                        }
                        else -> throw IllegalArgumentException()
                    }
                    else -> {
                        require(char >= ' ')
                        out.append(char)
                    }
                }
            }
        }

        private fun number(): Any {
            val start = at
            while (at < text.length && text[at] in NUMBER_CHARS) at++
            val raw = text.substring(start, at)
            require(raw.isNotEmpty() && raw[0] != '+')
            return if (raw.none { it == '.' || it == 'e' || it == 'E' }) raw.toLongOrNull() ?: raw.toDouble() else raw.toDouble()
        }

        private fun literal(word: String, value: Any?): Any? {
            require(text.startsWith(word, at))
            at += word.length
            return value
        }

        private fun skipSpace() {
            while (at < text.length && (text[at] == ' ' || text[at] == '\n' || text[at] == '\r' || text[at] == '\t')) at++
        }
    }

    private const val MAX_DEPTH = 32
    private const val NUMBER_CHARS = "+-0123456789.eE"
}
