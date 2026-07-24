package ai.desertant.core

import android.content.SharedPreferences
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
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
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.long

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
 * Model-agnostic and reusable. Published as the `ai.desertant:core` Android
 * artifact (kotlin/build.gradle.kts); model SDKs depend on it rather than
 * vendoring this file.
 */
object HostBridge {
    /**
     * NFKC-normalize [textUtf8] with the platform's own java.text.Normalizer
     * (available since API 1), so the Swift core links no ICU on Android and the
     * SDK is not pinned to the API 31 platform libicu. Returns UTF-8 bytes.
     */
    @JvmStatic
    fun normalizeNfkc(textUtf8: ByteArray): ByteArray =
        java.text.Normalizer.normalize(textUtf8.toString(Charsets.UTF_8), java.text.Normalizer.Form.NFKC)
            .toByteArray(Charsets.UTF_8)

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
    /// GET the Hugging Face tree API and return its files as one
    /// `path\tsize\tsha256` line each (empty sha256 for non-LFS files), so the
    /// Swift ModelStore can expand folders and verify. Empty result on failure.
    @JvmStatic
    fun httpTree(urlUtf8: ByteArray): ByteArray {
        return try {
            val conn = URL(urlUtf8.toString(Charsets.UTF_8)).openConnection() as HttpURLConnection
            conn.instanceFollowRedirects = true
            val json = conn.inputStream.bufferedReader().use { it.readText() }
            conn.disconnect()
            val sb = StringBuilder()
            for (item in Json.parseToJsonElement(json).jsonArray) {
                val o = item.jsonObject
                if (o["type"]?.let { (it as? JsonPrimitive)?.content } != "file") continue
                val path = (o["path"] as JsonPrimitive).content
                val size = (o["size"] as JsonPrimitive).long
                val sha = (o["lfs"] as? JsonObject)?.get("oid")?.let { (it as JsonPrimitive).content } ?: ""
                sb.append(path).append('\t').append(size).append('\t').append(sha).append('\n')
            }
            sb.toString().toByteArray(Charsets.UTF_8)
        } catch (e: Exception) {
            ByteArray(0)
        }
    }

    /// Download a URL to a file path (following redirects to the LFS CDN).
    /// Returns 0 on success, -1 on failure.
    @JvmStatic
    fun httpDownload(urlUtf8: ByteArray, destUtf8: ByteArray): Int {
        return try {
            val dest = File(destUtf8.toString(Charsets.UTF_8))
            dest.parentFile?.mkdirs()
            val conn = URL(urlUtf8.toString(Charsets.UTF_8)).openConnection() as HttpURLConnection
            conn.instanceFollowRedirects = true
            conn.inputStream.use { input -> dest.outputStream().use { out -> input.copyTo(out) } }
            conn.disconnect()
            0
        } catch (e: Exception) {
            -1
        }
    }

    /**
     * Small key/value persistence for desert-ant-core's `Usage` state, backed by
     * SharedPreferences. The host app sets [preferences] once (e.g.
     * `HostBridge.preferences = context.getSharedPreferences("desert-ant", MODE_PRIVATE)`);
     * until then get returns empty and set is a no-op (state simply doesn't persist).
     */
    @JvmStatic
    var preferences: SharedPreferences? = null

    @JvmStatic
    fun prefsGet(keyUtf8: ByteArray): ByteArray {
        val value = preferences?.getString(keyUtf8.toString(Charsets.UTF_8), null)
        return value?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
    }

    @JvmStatic
    fun prefsSet(keyUtf8: ByteArray, valueUtf8: ByteArray) {
        preferences?.edit()
            ?.putString(keyUtf8.toString(Charsets.UTF_8), valueUtf8.toString(Charsets.UTF_8))
            ?.apply()
    }

    /**
     * The application identity used as the usage turnstile key. The host app sets
     * this once (e.g. `HostBridge.applicationId = context.packageName`).
     */
    @JvmStatic
    var applicationId: String? = null

    @JvmStatic
    fun appId(): ByteArray = (applicationId ?: "").toByteArray(Charsets.UTF_8)

    /**
     * Flush pending usage for all active sessions. The host calls this from an
     * app-background lifecycle callback, e.g.:
     *   ProcessLifecycleOwner.get().lifecycle.addObserver(LifecycleEventObserver { _, e ->
     *     if (e == Lifecycle.Event.ON_STOP) HostBridge.flushUsage()
     *   })
     * Implemented natively (desert-ant-core Inference); requires the SDK's .so loaded.
     */
    @JvmStatic external fun flushUsage()

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
