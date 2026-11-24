package ai.desertant.tongue.license

import com.sun.net.httpserver.HttpServer
import java.io.File
import java.net.InetSocketAddress
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.PKCS8EncodedKeySpec
import java.time.Instant
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList

internal const val DEAD_ENDPOINT = "http://127.0.0.1:9/api/v1"

internal object Vectors {
    val document: Map<String, Any?> =
        Json.parseObject(File("../../Tests/UsageTests/Resources/license_vectors.json").readText())!!

    @Suppress("UNCHECKED_CAST")
    fun rows(name: String): List<Map<String, Any?>> = document.getValue(name) as List<Map<String, Any?>>

    val publicKeys: Map<String, String> = rows("keys").associate { it["kid"] as String to it["publicKeyX963"] as String }

    /** A license the vector key `test-2` signs, valid from a minute before [now] for [days] days. */
    fun mint(now: Long = System.currentTimeMillis(), days: Long = 30, licenseId: String = "7e33d8a7-32c1-8f75-9fc5-88a8a6e19e43"): String {
        val url = Base64.getUrlEncoder().withoutPadding()
        val end = Instant.ofEpochMilli(now + days * DAY_MS).toString()
        val header = url.encodeToString("""{"alg":"ES256","kid":"test-2","typ":"dal-license+jwt"}""".toByteArray())
        val payload = url.encodeToString(
            """{"v":1,"lid":"$licenseId","period":"2026-11","periodEnd":"$end","iat":${now / 1000 - 60}}""".toByteArray(),
        )
        val pkcs8 = rows("keys").first { it["kid"] == "test-2" }["privateKeyPkcs8"] as String
        val signature = Signature.getInstance("SHA256withECDSAinP1363Format").run {
            initSign(KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(Base64.getDecoder().decode(pkcs8))))
            update("$header.$payload".toByteArray())
            sign()
        }
        return "$header.$payload.${url.encodeToString(signature)}"
    }
}

internal class Request(val path: String, val authorization: String?, val contentType: String?, val body: Map<String, Any?>) {
    val isBatch: Boolean get() = path.endsWith("/licenses")

    /** The install ids the request asks for: one for a grant, each item's for a batch. */
    val installIds: List<Any?>
        get() = if (isBatch) (body["items"] as List<*>).map { (it as Map<*, *>)["installId"] } else listOf(body["installId"])
}

internal class Answer(val status: Int, val body: String, val retryAfter: String? = null)

internal fun granted(): Answer =
    Answer(200, """{"token":"${Vectors.mint()}","serverTime":"${Instant.ofEpochMilli(System.currentTimeMillis())}"}""")

/** A license for each item of a batch, with [tokens] in place of the first ones (null for an item without a token). */
internal fun grantedBatch(request: Request, tokens: List<String?> = emptyList()): Answer {
    val valid = Vectors.mint()
    val results = request.installIds.indices.joinToString(",") { index ->
        val token = if (index < tokens.size) tokens[index] else valid
        if (token == null) "{}" else """{"token":"$token"}"""
    }
    return Answer(200, """{"serverTime":"${Instant.ofEpochMilli(System.currentTimeMillis())}","results":[$results]}""")
}

internal fun grantedEither(request: Request): Answer = if (request.isBatch) grantedBatch(request) else granted()

/** A license server on 127.0.0.1 that records every request it gets. */
internal class FakeLicenseServer(private val answer: (Request) -> Answer = ::grantedEither) : AutoCloseable {
    val requests = CopyOnWriteArrayList<Request>()
    private val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
    val endpoint: String get() = "http://127.0.0.1:${server.address.port}/api/v1/"

    init {
        server.createContext("/") { exchange ->
            val request = Request(
                exchange.requestURI.path,
                exchange.requestHeaders.getFirst("Authorization"),
                exchange.requestHeaders.getFirst("Content-Type"),
                Json.parseObject(exchange.requestBody.readBytes().toString(Charsets.UTF_8)) ?: emptyMap(),
            )
            requests += request
            val reply = answer(request)
            val bytes = reply.body.toByteArray()
            reply.retryAfter?.let { exchange.responseHeaders.add("Retry-After", it) }
            exchange.sendResponseHeaders(reply.status, bytes.size.toLong().takeIf { it > 0 } ?: -1)
            if (bytes.isNotEmpty()) exchange.responseBody.use { it.write(bytes) }
            exchange.close()
        }
        server.executor = java.util.concurrent.Executors.newCachedThreadPool { Thread(it).apply { isDaemon = true } }
        server.start()
    }

    override fun close() = server.stop(0)
}

internal fun testRuntime(
    endpoint: String,
    store: LicenseStore = MemoryStore(),
    platform: String = "server",
    apiKey: String? = "dal_test_key",
    secret: String? = null,
    warnings: MutableList<String> = CopyOnWriteArrayList(),
    keepsLicenses: () -> Boolean = { true },
    post: (String, ByteArray, String?) -> HttpReply? = ::httpPost,
    coreIsPresent: () -> Boolean = { false },
    sleep: (Long) -> Unit = {},
): LicenseRuntime = LicenseRuntime(
    LicenseDeps(
        store = { store },
        identity = { LicenseIdentity("com.acme.app", apiKey, platform) },
        secret = { secret },
        endpoint = { endpoint },
        publicKeys = Vectors.publicKeys,
        warn = { warnings += it },
        keepsLicenses = keepsLicenses,
        post = post,
        coreIsPresent = coreIsPresent,
        sleep = sleep,
    ),
)

/** Runs [body] with [runtime] as the one every Tongue in the process uses. */
internal fun <T> withRuntime(runtime: LicenseRuntime, body: () -> T): T {
    Licensing.use(runtime)
    try {
        return body()
    } finally {
        Licensing.use(null)
    }
}
