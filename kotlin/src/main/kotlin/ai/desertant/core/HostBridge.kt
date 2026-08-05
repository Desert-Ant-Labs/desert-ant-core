package ai.desertant.core

import android.content.SharedPreferences
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.nio.ByteOrder
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

    /**
     * Decode an audio file (any container/codec MediaCodec supports) to mono
     * `Float` PCM at [sampleRate], the counterpart of Swift AudioIO's decode on
     * Android. Pass the file path as [pathUtf8], or the file bytes as [data]
     * (staged to a temp file, since MediaExtractor reads a path/fd). Returns the
     * length-prefixed FFI buffer AudioIO expects: big-endian u32 body length,
     * then u32 sample rate, then a float32 array (u32 count, then big-endian
     * floats). Empty result on failure ("leave it to the caller").
     */
    @JvmStatic
    fun audioDecode(pathUtf8: ByteArray?, data: ByteArray?, sampleRate: Double): ByteArray {
        var temp: File? = null
        return try {
            val path = when {
                pathUtf8 != null -> pathUtf8.toString(Charsets.UTF_8)
                data != null -> {
                    val f = File.createTempFile("dal-audio", ".bin")
                    f.writeBytes(data)
                    temp = f
                    f.absolutePath
                }
                else -> return ByteArray(0)
            }
            val (pcm, srcRate, channels) = decodePcmMono16(path)
            val mono = if (channels > 1) mixdownMono(pcm, channels) else pcm
            val resampled = resampleLinear(mono, srcRate.toDouble(), sampleRate)
            encodeAudioBuffer(sampleRate.toInt(), resampled)
        } catch (e: Exception) {
            ByteArray(0)
        } finally {
            temp?.delete()
        }
    }

    // Decode via MediaExtractor + MediaCodec to interleaved 16-bit PCM ->
    // Float in [-1, 1]. Synchronous (dequeue) loop; the model SDKs decode whole
    // files, not streams.
    private fun decodePcmMono16(path: String): Triple<FloatArray, Int, Int> {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        var track = -1
        var format: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                track = i; format = f; break
            }
        }
        if (track < 0 || format == null) { extractor.release(); throw IllegalStateException("no audio track") }
        extractor.selectTrack(track)
        val srcRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val mime = format.getString(MediaFormat.KEY_MIME)!!

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, null, null, 0)
        codec.start()
        val info = MediaCodec.BufferInfo()
        val out = ArrayList<Float>()
        var sawInputEnd = false
        var sawOutputEnd = false
        while (!sawOutputEnd) {
            if (!sawInputEnd) {
                val inIndex = codec.dequeueInputBuffer(10_000)
                if (inIndex >= 0) {
                    val buf = codec.getInputBuffer(inIndex)!!
                    val size = extractor.readSampleData(buf, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        sawInputEnd = true
                    } else {
                        codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }
            val outIndex = codec.dequeueOutputBuffer(info, 10_000)
            if (outIndex >= 0) {
                if (info.size > 0) {
                    val buf = codec.getOutputBuffer(outIndex)!!
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val shorts = buf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                    while (shorts.hasRemaining()) out.add(shorts.get() / 32768f)
                }
                codec.releaseOutputBuffer(outIndex, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) sawOutputEnd = true
            }
        }
        codec.stop(); codec.release(); extractor.release()
        return Triple(out.toFloatArray(), srcRate, channels)
    }

    private fun mixdownMono(interleaved: FloatArray, channels: Int): FloatArray {
        val frames = interleaved.size / channels
        val out = FloatArray(frames)
        val inv = 1f / channels
        for (f in 0 until frames) {
            var acc = 0f
            val base = f * channels
            for (c in 0 until channels) acc += interleaved[base + c]
            out[f] = acc * inv
        }
        return out
    }

    private fun resampleLinear(x: FloatArray, from: Double, to: Double): FloatArray {
        if (from <= 0 || to <= 0 || from == to || x.size < 2) return x
        val outCount = Math.round(x.size * (to / from)).toInt()
        if (outCount <= 0) return FloatArray(0)
        val out = FloatArray(outCount)
        val step = from / to
        for (i in 0 until outCount) {
            val src = i * step
            val i0 = src.toInt()
            if (i0 >= x.size - 1) { out[i] = x[x.size - 1]; continue }
            val frac = (src - i0).toFloat()
            out[i] = x[i0] * (1 - frac) + x[i0 + 1] * frac
        }
        return out
    }

    // FFI buffer: big-endian u32 body length, then u32 sample rate, then an
    // f32 array (u32 count + big-endian floats), matching Swift's FFIReader.
    private fun encodeAudioBuffer(sampleRate: Int, samples: FloatArray): ByteArray {
        val body = ByteArrayOutputStream()
        DataOutputStream(body).use { d ->
            d.writeInt(sampleRate)
            d.writeInt(samples.size)
            for (v in samples) d.writeFloat(v)
        }
        val tree = body.toByteArray()
        val out = ByteArrayOutputStream()
        DataOutputStream(out).use { it.writeInt(tree.size); it.write(tree) }
        return out.toByteArray()
    }

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

/**
 * Writes the payloads the native side reads with Swift's `FFIReader`: the
 * per-model options a run takes. Same encoding as [FfiReader] reads.
 *
 * This keeps every model JNI bridge on the same small method shape: options are
 * a payload the model decodes rather than a model-specific argument list.
 */
class FfiWriter {
    private val out = ByteArrayOutputStream()
    private val data = DataOutputStream(out)

    /** Append a big-endian int. */
    fun int(v: Int): FfiWriter = apply { data.writeInt(v) }

    /** Append a big-endian IEEE-754 double. */
    fun double(v: Double): FfiWriter = apply { data.writeDouble(v) }

    /** Append a uint32 UTF-8 byte count, then the UTF-8 bytes. */
    fun string(s: String): FfiWriter = apply {
        val bytes = s.toByteArray(Charsets.UTF_8)
        data.writeInt(bytes.size)
        data.write(bytes)
    }

    /** Append an int count, then that many length-prefixed strings. */
    fun strings(values: Collection<String>): FfiWriter = apply {
        data.writeInt(values.size)
        for (s in values) string(s)
    }

    /** Append an int byte count, then the raw bytes. */
    fun blob(bytes: ByteArray): FfiWriter = apply {
        data.writeInt(bytes.size)
        data.write(bytes)
    }

    /** The finished payload (no outer length prefix). */
    fun done(): ByteArray {
        data.flush()
        return out.toByteArray()
    }
}
