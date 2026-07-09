package ai.desertant.core

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.nio.ByteBuffer
import java.util.regex.Pattern
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull

/**
 * The Android host side of desert-ant-core's Swift JNI harness (the counterpart
 * to Sources/HostBridge/JNI.swift). A pure-Swift model core must not link
 * Foundation on Android (it would add tens of megabytes of ICU), so its Regex
 * and JSON primitives call back here through CHostBridge to use the platform's
 * own java.util.regex and JSON parser.
 *
 * A model's native class exposes thin `@JvmStatic` forwarders named exactly
 * `regexMatches` and `jsonParseTree` (the signatures the Swift
 * `installHostBridge` looks up on the class passed to JNI) that delegate here.
 *
 * Model-agnostic and reusable. Until a desert-ant-core Android artifact is
 * published, model SDKs vendor this file verbatim.
 */
object HostBridge {
    /**
     * Run [patternUtf8] over [textUtf8] with java.util.regex and return the
     * matches as newline-separated rows, each `g0s,g0e;g1s,g1e;...` of UTF-16
     * group offsets (`-1,-1` for an unmatched group). [firstOnly] stops after
     * the first match.
     */
    @JvmStatic
    fun regexMatches(
        patternUtf8: ByteArray,
        caseInsensitive: Boolean,
        textUtf8: ByteArray,
        firstOnly: Boolean,
    ): ByteArray {
        val flags = if (caseInsensitive) Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE else 0
        val pattern = Pattern.compile(patternUtf8.toString(Charsets.UTF_8), flags)
        val matcher = pattern.matcher(textUtf8.toString(Charsets.UTF_8))
        val out = StringBuilder()
        while (matcher.find()) {
            if (out.isNotEmpty()) out.append('\n')
            for (i in 0..matcher.groupCount()) {
                if (i > 0) out.append(';')
                out.append(matcher.start(i)).append(',').append(matcher.end(i))
            }
            if (firstOnly) break
        }
        return out.toString().toByteArray(Charsets.UTF_8)
    }

    /**
     * Parse [jsonUtf8] with the platform parser (kotlinx.serialization) and emit
     * the compact binary value tree desert-ant-core's JSON module decodes, so
     * the Swift core hand-rolls no JSON on Android. Format: big-endian u32
     * payload length, then nodes tagged 0 null, 1 false, 2 true, 3 f64,
     * 4 string(u32+utf8), 5 array(u32 count+nodes),
     * 6 object(u32 count+[u32 keyLen+key, node]).
     */
    @JvmStatic
    fun jsonParseTree(jsonUtf8: ByteArray): ByteArray {
        val root = Json.parseToJsonElement(jsonUtf8.toString(Charsets.UTF_8))
        val body = ByteArrayOutputStream()
        DataOutputStream(body).use { encodeJson(root, it) }
        val tree = body.toByteArray()
        val out = ByteArrayOutputStream()
        DataOutputStream(out).use { it.writeInt(tree.size); it.write(tree) }
        return out.toByteArray()
    }

    private fun encodeJson(e: JsonElement, out: DataOutputStream) {
        when (e) {
            is JsonNull -> out.writeByte(0)
            is JsonObject -> {
                out.writeByte(6); out.writeInt(e.size)
                for ((key, value) in e) { writeUtf8(out, key); encodeJson(value, out) }
            }
            is JsonArray -> {
                out.writeByte(5); out.writeInt(e.size)
                for (item in e) encodeJson(item, out)
            }
            is JsonPrimitive -> when {
                e.isString -> { out.writeByte(4); writeUtf8(out, e.content) }
                e.booleanOrNull != null -> out.writeByte(if (e.booleanOrNull == true) 2 else 1)
                e.doubleOrNull != null -> { out.writeByte(3); out.writeDouble(e.doubleOrNull!!) }
                else -> { out.writeByte(4); writeUtf8(out, e.content) }
            }
        }
    }

    private fun writeUtf8(out: DataOutputStream, s: String) {
        val bytes = s.toByteArray(Charsets.UTF_8)
        out.writeInt(bytes.size)
        out.write(bytes)
    }
}

/**
 * Reads an FFIWriter result buffer: big-endian ints/longs, IEEE-754 doubles,
 * and uint32-length-prefixed UTF-8 strings, matching Sources/FFIBuffer. Wraps
 * java.nio.ByteBuffer (big-endian by default), so the model decodes native
 * results with the JVM standard library and no hand-rolled parsing.
 */
class FfiReader(bytes: ByteArray) {
    private val buf: ByteBuffer = ByteBuffer.wrap(bytes)

    fun int(): Int = buf.int
    fun double(): Double = buf.double

    fun string(): String {
        val b = ByteArray(buf.int)
        buf.get(b)
        return String(b, Charsets.UTF_8)
    }
}
