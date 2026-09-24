package ai.desertant.core

import android.content.Context
import android.content.SharedPreferences
import android.content.res.Configuration
import android.os.Build
import android.os.LocaleList
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
import java.util.Locale
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
 * Published as the `ai.desertant:core` Android artifact (kotlin/build.gradle.kts).
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
     * Perform [methodUtf8] on [urlUtf8] with an optional [body] and content
     * type, for desert-ant-core's HTTP client (the usage POST). Returns the
     * 4-byte big-endian status, the 4-byte big-endian body length, then the
     * body; an error status comes back the same way, with its body. Null on a
     * transport failure. Bounded by [HTTP_TIMEOUT_MS] per connect and read, as
     * the Swift side's timeout does not cross the bridge.
     */
    @JvmStatic
    fun httpRequest(
        methodUtf8: ByteArray,
        urlUtf8: ByteArray,
        body: ByteArray?,
        contentTypeUtf8: ByteArray?,
    ): ByteArray? {
        return try {
            val conn = URL(urlUtf8.toString(Charsets.UTF_8)).openConnection() as HttpURLConnection
            conn.requestMethod = methodUtf8.toString(Charsets.UTF_8)
            conn.connectTimeout = HTTP_TIMEOUT_MS
            conn.readTimeout = HTTP_TIMEOUT_MS
            contentTypeUtf8?.let { conn.setRequestProperty("Content-Type", it.toString(Charsets.UTF_8)) }
            if (body != null) {
                conn.doOutput = true
                conn.setFixedLengthStreamingMode(body.size)
                conn.outputStream.use { it.write(body) }
            }
            val status = conn.responseCode
            val stream = if (status >= 400) conn.errorStream else conn.inputStream
            val response = stream?.use { it.readBytes() } ?: ByteArray(0)
            conn.disconnect()
            ByteBuffer.allocate(8 + response.size).putInt(status).putInt(response.size).put(response).array()
        } catch (e: Exception) {
            null
        }
    }

    private const val HTTP_TIMEOUT_MS = 5_000

    /**
     * Fill in the app identity and the usage store from [context], so usage is
     * keyed by the real package and the device id survives the process. Every
     * [LoadedModel] built from a Context calls this before creating its native
     * handle, so a host app does not have to.
     *
     * Only unset values are filled: a host that assigned [applicationId] or
     * [preferences] itself keeps them. The store is the "desert-ant"
     * SharedPreferences file, the same one ai.desertant:tongue uses, so an app
     * embedding both and giving them the same kind of Context keeps one device
     * id rather than counting as two devices.
     *
     * The store comes from [context] as passed, not its application context, so
     * a direct-boot-aware app that passes a device-protected Context keeps usage
     * persisting before the first unlock. With a credential-protected Context
     * before unlock, SharedPreferences throw; the store is then left unset
     * (usage just does not persist yet) rather than failing the model's
     * constructor, and the next model built after unlock fills it.
     */
    @JvmStatic
    fun attach(context: Context) {
        attach(context.packageName, { androidDeviceFacts(context) }) {
            context.getSharedPreferences(PREFERENCES_FILE, Context.MODE_PRIVATE)
        }
    }

    /**
     * [attach] without a Context, so its rules are testable on the JVM. [store]
     * is only opened when no store is set yet, and a RuntimeException from it
     * (the pre-unlock IllegalStateException) leaves the store unset. [facts] is
     * read once per process, by the first attach.
     */
    @Synchronized
    internal fun attach(
        packageName: String,
        facts: () -> String = { "" },
        store: () -> SharedPreferences,
    ) {
        if (applicationId == null) applicationId = packageName
        if (preferences == null) {
            preferences = try { store() } catch (_: RuntimeException) { null }
        }
        if (deviceFacts == null) deviceFacts = facts()
    }

    private const val PREFERENCES_FILE = "desert-ant"

    /**
     * Small key/value persistence for desert-ant-core's `Usage` state, backed by
     * SharedPreferences. [attach] sets it to the "desert-ant" file when a model is
     * created; a host that wants a different store assigns it before that. While
     * it is null get returns empty and set is a no-op (state simply doesn't
     * persist, so every load looks like a new device).
     */
    @JvmStatic
    @Volatile
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
     * The application identity used as the usage turnstile key. [attach] sets it
     * to the package name when a model is created; a host that wants a different
     * key assigns it before that. While it is null the native side reports
     * "unknown".
     */
    @JvmStatic
    @Volatile
    var applicationId: String? = null

    @JvmStatic
    fun appId(): ByteArray = (applicationId ?: "").toByteArray(Charsets.UTF_8)

    /**
     * Whether usage events carry the device context: the app version, OS
     * version, device model, form factor and locale [attach] reads (see
     * desert-ant-core's Sources/Usage/DeviceContext.swift). `true` by default.
     * Setting it to `false` sends usage without any context, the Android form
     * of Swift's `DesertAnt.sendsDeviceContext`. Read per event, so it applies
     * from the next send on.
     */
    @JvmStatic
    @Volatile
    var sendsDeviceContext: Boolean = true

    /** The facts [attach] read, as [deviceContext] returns them. Null until then. */
    @Volatile
    internal var deviceFacts: String? = null

    /**
     * The device facts for the usage context as `key=value` lines, empty before
     * [attach] or while [sendsDeviceContext] is off. The native side caps and
     * filters them, and for a host-supplied device id (`DAL_DEVICE_ID`) sends
     * only the OS, its major version and the app version.
     */
    @JvmStatic
    fun deviceContext(): ByteArray =
        (if (sendsDeviceContext) deviceFacts.orEmpty() else "").toByteArray(Charsets.UTF_8)

    /**
     * The facts from [context]. Nothing here needs a permission, and nothing
     * identifies the device: no serial, ANDROID_ID or build fingerprint.
     */
    @Suppress("DEPRECATION") // getPackageInfo(String, Int): the flags overload is API 33+.
    private fun androidDeviceFacts(context: Context): String = deviceFactLines(
        appVersion = { context.packageManager.getPackageInfo(context.packageName, 0).versionName },
        osRelease = { Build.VERSION.RELEASE },
        model = { Build.MODEL },
        // The application's configuration, not an Activity's: a tablet Activity in
        // split screen can report under 600dp, and the facts last the process.
        smallestWidthDp = { (context.applicationContext ?: context).resources.configuration.smallestScreenWidthDp },
        locale = { LocaleList.getDefault().get(0) },
    )

    /**
     * The context lines from each fact's reader. A reader that throws, or
     * returns nothing usable, leaves its key out rather than failing the
     * model's constructor.
     */
    internal fun deviceFactLines(
        appVersion: () -> String?,
        osRelease: () -> String?,
        model: () -> String?,
        smallestWidthDp: () -> Int,
        locale: () -> Locale?,
    ): String {
        val facts = linkedMapOf<String, String?>("osName" to "Android")
        facts["appVersion"] = read(appVersion)
        facts["osVersion"] = read(osRelease)?.let(::majorMinor)
        facts["deviceModel"] = read(model)
        facts["formFactor"] = read(smallestWidthDp)?.let(::formFactor)
        facts["locale"] = read(locale)?.let(::languageRegion)
        return facts.entries
            .mapNotNull { (key, raw) ->
                // A line break would split the value into a line of its own.
                val value = raw?.trim()
                if (value.isNullOrEmpty() || value.any { it == '\n' || it == '\r' }) null else "$key=$value"
            }
            .joinToString("\n")
    }

    private fun <T> read(fact: () -> T?): T? = try { fact() } catch (_: Exception) { null }

    /** "8.1.0" -> "8.1", "14" -> "14". Null when it does not start with a number. */
    internal fun majorMinor(release: String): String? {
        val numeric = release.trim().takeWhile { it.isDigit() || it == '.' }
        return numeric.split('.').filter { it.isNotEmpty() }.take(2).joinToString(".").ifEmpty { null }
    }

    /** Google's own tablet line: a smallest width of 600dp or more. */
    internal fun formFactor(smallestWidthDp: Int): String? = when {
        smallestWidthDp == Configuration.SMALLEST_SCREEN_WIDTH_DP_UNDEFINED -> null
        smallestWidthDp >= 600 -> "tablet"
        else -> "mobile"
    }

    /**
     * Language and region only: "zh-Hant-TW" -> "zh-TW", "fr" -> "fr". Through
     * the language tag, so Hebrew reads "he" rather than the legacy "iw".
     */
    internal fun languageRegion(locale: Locale): String? {
        val language = locale.toLanguageTag().substringBefore('-')
        if (language.isEmpty() || language == "und") return null
        return if (locale.country.isEmpty()) language else "$language-${locale.country}"
    }

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

    /** Whether any bytes are left, for fields appended after a first release. */
    fun hasRemaining(): Boolean = buf.hasRemaining()

    /** Read an int count, then that many big-endian floats: the audio payload. */
    fun floats(): FloatArray {
        val out = FloatArray(buf.int)
        for (i in out.indices) out[i] = buf.float
        return out
    }

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

    /** Append an int element count, then that many big-endian floats: the
     *  portable audio payload, matching Swift's `FFIWriter.f32Array`. */
    fun floats(values: FloatArray): FfiWriter = apply {
        data.writeInt(values.size)
        for (v in values) data.writeFloat(v)
    }

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
