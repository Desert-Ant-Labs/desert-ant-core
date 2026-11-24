package ai.desertant.tongue.license

import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

// Sources/Usage/DeviceInstall.swift is the reference: the same inputs give the same id there.
internal fun deviceInstallId(deviceId: String, app: String, secret: String?, apiKey: String? = null): String {
    val parts = mutableListOf("dal-device-install/v1", app.trim().lowercase(), deviceId)
    if (secret == null && apiKey != null) parts += apiKey
    val message = java.io.ByteArrayOutputStream()
    for (part in parts) {
        val bytes = part.toByteArray(Charsets.UTF_8)
        message.write(byteArrayOf((bytes.size ushr 24).toByte(), (bytes.size ushr 16).toByte(), (bytes.size ushr 8).toByte(), bytes.size.toByte()))
        message.write(bytes)
    }
    val hash = if (secret == null) {
        MessageDigest.getInstance("SHA-256").digest(message.toByteArray())
    } else {
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(secret.toByteArray(Charsets.UTF_8), "HmacSHA256"))
            doFinal(message.toByteArray())
        }
    }
    val id = hash.copyOf(16)
    id[6] = ((id[6].toInt() and 0x0f) or 0x80).toByte()
    id[8] = ((id[8].toInt() and 0x3f) or 0x80).toByte()
    val hex = id.joinToString("") { "%02x".format(it) }
    return listOf(0..7, 8..11, 12..15, 16..19, 20..31).joinToString("-") { hex.substring(it) }
}

// Until when each device needs no request: its license's expiry, a day after a refusal, a minute while its request waits.
internal class DeviceLicenseHolds(private val capacity: Int = DEVICE_LICENSE_CAPACITY) {
    private val heldUntil = HashMap<String, Long>()

    @Synchronized
    fun begin(deviceId: String, now: Long): Boolean {
        val held = heldUntil[deviceId]
        if (held != null && now < held) return false
        if (held == null && heldUntil.size >= capacity) {
            heldUntil.values.removeAll { now >= it }
            // Forgetting a device only sends its request again, and the server answers with the same license.
            if (heldUntil.size >= capacity) {
                heldUntil.keys.take(capacity / 2 + 1).forEach(heldUntil::remove)
            }
        }
        heldUntil[deviceId] = now + DEVICE_LICENSE_REQUEST_HOLD_MS
        return true
    }

    @Synchronized
    fun hold(deviceId: String, until: Long) {
        if (deviceId in heldUntil || heldUntil.size < capacity) heldUntil[deviceId] = until
    }

    val count: Int @Synchronized get() = heldUntil.size
}

/** When the device requests may start again. A flush sends before [retryAt], and not before [serverWaitUntil]. */
internal class DeviceRetryWait {
    var attempts = 0
        private set
    var retryAt = 0L
        private set
    var serverWaitUntil = 0L
        private set

    /** The wait after a request failed: [reply] is null when the server gave no answer. */
    fun failed(reply: HttpReply?, now: Long, jitter: (Long) -> Long): Long {
        if (reply == null) {
            retryAt = maxOf(now + LICENSE_NETWORK_RETRY_MS, serverWaitUntil)
        } else {
            retryAt = now + licenseBackoff(attempts++, licenseRetryAfter(reply), jitter)
            serverWaitUntil = retryAt
        }
        return maxOf(retryAt - now, 0)
    }

    fun succeeded() {
        attempts = 0
        retryAt = 0
        serverWaitUntil = 0
    }
}

// Sources/Usage/DeviceLicensing.swift is the reference. One request is on its way at a time, and a failed one stops new ones until its retry time.
internal class DeviceLicenseClient(
    private val deps: LicenseDeps,
    private val start: (work: () -> Unit) -> Boolean,
    private val schedule: (delayMs: Long, work: () -> Unit) -> Unit,
    val holds: DeviceLicenseHolds = DeviceLicenseHolds(),
    private val queueLimit: Int = DEVICE_LICENSE_QUEUE_LIMIT,
    private val batchItems: Int = DEVICE_LICENSE_BATCH_ITEMS,
) {
    private class Wanted(val deviceId: String, val since: Long)

    private class Failure(val reply: HttpReply?, val cause: String)

    private val servesFromAServer by lazy { deps.identity().platform == "server" }
    private val queue = ArrayDeque<Wanted>()
    private val queued = HashSet<String>()
    private val warned = HashSet<String>()
    private var sending = false
    private val wait = DeviceRetryWait()
    private var singleGrantsUntil = 0L
    private var forcing = false
    private var flushes = 0
    private var flushEnds: Long? = null
    private var timerDue: Long? = null
    private var timerGeneration = 0

    val pending: Int @Synchronized get() = queued.size

    fun modelRan(deviceId: String?) {
        // A phone is one device, which its install license covers.
        if (!servesFromAServer) return
        val hasSecret = deps.secret() != null
        if (deviceId.isNullOrEmpty()) {
            if (hasSecret) {
                warnOnce("This call has no deviceId, so it gets no device license. Pass a deviceId with every call. See $RUN_ON_A_SERVER_GUIDE")
            }
            return
        }
        if (!holds.begin(deviceId, deps.now())) return
        if (!hasSecret) {
            warnOnce("deviceId is hashed without a secret, so a guessed device id can be matched to its install id. Set deviceIdSecret in DesertAnt.configure. See $RUN_ON_A_SERVER_GUIDE")
        }
        license(deviceId)
    }

    @Synchronized
    private fun license(deviceId: String) {
        if (deviceId in queued) return
        // A device left out of a full queue asks again on a later run, when its hold ends.
        if (queued.size >= queueLimit) {
            warnOnce("The license queue is full ($queueLimit devices wait), so new devices are left out and get a license on a later call. The model keeps running. Check that the license server is reachable and answers in time. See $RUN_ON_A_SERVER_GUIDE")
            return
        }
        queued += deviceId
        queue.addLast(Wanted(deviceId, deps.now()))
        pump(force = false)
    }

    /** From now until [endLimit], no request starts after [end]. With several limits, the earliest holds. */
    @Synchronized
    fun limitSends(end: Long) {
        flushes++
        flushEnds = minOf(flushEnds ?: Long.MAX_VALUE, end)
    }

    @Synchronized
    fun endLimit() {
        flushes--
        if (flushes == 0) {
            flushEnds = null
            forcing = false
        }
    }

    /** Starts the requests that may start now. With [force], also before a batch is full and before a connection retry is due. */
    @Synchronized
    fun pump(force: Boolean) {
        if (force) forcing = true
        val left = (if (forcing) wait.serverWaitUntil else wait.retryAt) - deps.now()
        if (left > 0) {
            arm(left)
            return
        }
        while (queue.isNotEmpty()) {
            val now = deps.now()
            if (flushEnds?.let { now >= it } == true) {
                arm(DEVICE_LICENSE_WAIT_MS)
                return
            }
            // A batch needs an API key the server takes batches from. Without one, each device is one request.
            val batches = deps.identity().apiKey != null && now >= singleGrantsUntil
            if (sending) return
            // Less than a batch waits for more devices, until the oldest has waited its time.
            if (!forcing && queue.size < batchItems) {
                val early = queue.first().since + DEVICE_LICENSE_WAIT_MS - now
                if (early > 0 && early <= DEVICE_LICENSE_WAIT_MS) {
                    arm(early)
                    return
                }
            }
            val sent = List(if (batches) minOf(batchItems, queue.size) else 1) { queue.removeFirst() }
            sending = true
            val started = try {
                start { if (batches) requestBatch(sent) else requestSingle(sent[0]) }
            } catch (_: Throwable) {
                false
            }
            if (!started) {
                sending = false
                requeue(sent)
                arm(DEVICE_LICENSE_WAIT_MS)
                return
            }
        }
    }

    private fun requeue(sent: List<Wanted>) = sent.asReversed().forEach(queue::addFirst)

    // One timer at a time. A sooner one replaces a later one, and the replaced one does nothing when it fires.
    private fun arm(delay: Long) {
        val due = deps.now() + delay.coerceIn(0, LICENSE_MAX_BACKOFF_MS)
        timerDue?.let { if (it <= due) return }
        timerDue = due
        val armed = ++timerGeneration
        schedule(due - deps.now()) { timerFired(armed) }
    }

    @Synchronized
    private fun timerFired(armed: Int) {
        if (armed != timerGeneration) return
        timerDue = null
        pump(force = false)
    }

    private fun installId(wanted: Wanted, who: LicenseIdentity): String =
        deviceInstallId(wanted.deviceId, "${who.platform}:${who.appId}", deps.secret(), who.apiKey)

    private fun requestBatch(batch: List<Wanted>) {
        var until: List<Long>? = null
        var failure: Failure? = null
        var refusal: HttpReply? = null
        try {
            val who = deps.identity()
            val reply = deps.send("licenses", batchBody(batch.map { installId(it, who) }, who), who)
            val received = deps.now()
            val action = reply?.let { licenseResponseAction(it.status, it.body) } ?: LicenseResponseAction.RETRY_NETWORK
            if (reply == null || action == LicenseResponseAction.RETRY_NETWORK) {
                failure = Failure(null, NO_ANSWER)
            } else if (action == LicenseResponseAction.TERMINAL || reply.status == 404) {
                refusal = reply
            } else {
                val answer = if (action == LicenseResponseAction.DONE) batchAnswer(reply.body) else null
                if (answer == null || answer.first.size != batch.size) {
                    failure = Failure(reply, if (action == LicenseResponseAction.DONE) "an answer the SDK cannot read" else "HTTP ${reply.status}")
                } else {
                    until = answer.first.map { expiry(it, answer.second, received) }
                }
            }
        } catch (_: Throwable) {
            failure = Failure(null, "an error in the SDK")
        }
        finish(batch, until, failure, refusal)
    }

    private fun requestSingle(wanted: Wanted) {
        var until = 0L
        var failure: Failure? = null
        try {
            val who = deps.identity()
            val reply = deps.send("license", grantBody(installId(wanted, who), who), who)
            val received = deps.now()
            when (reply?.let { licenseResponseAction(it.status, it.body) } ?: LicenseResponseAction.RETRY_NETWORK) {
                LicenseResponseAction.RETRY_NETWORK -> failure = Failure(null, NO_ANSWER)
                LicenseResponseAction.RETRY -> failure = Failure(reply, "HTTP ${reply?.status}")
                LicenseResponseAction.TERMINAL -> until = received + LICENSE_TERMINAL_WAIT_MS
                LicenseResponseAction.DONE -> {
                    val answer = reply?.let { grantAnswer(it.body) }
                    until = expiry(answer?.first, answer?.second, received)
                }
            }
        } catch (_: Throwable) {
            failure = Failure(null, "an error in the SDK")
        }
        finish(listOf(wanted), listOf(until), failure, null)
    }

    @Synchronized
    private fun finish(sent: List<Wanted>, until: List<Long>?, failure: Failure?, refusal: HttpReply?) {
        sending = false
        if (refusal != null) {
            // The key cannot batch, or the server has no batch route.
            singleGrantsUntil = deps.now() + DEVICE_LICENSE_SINGLE_GRANTS_MS
            if (refusal.status != 404) {
                warnOnce("The license server did not accept a batch (HTTP ${refusal.status}), so each device is one request for the next hour. A batch needs an API key of the Server platform. See $RUN_ON_A_SERVER_GUIDE")
            }
            requeue(sent)
            pump(force = false)
            return
        }
        if (failure == null && until != null) {
            wait.succeeded()
            sent.forEachIndexed { index, wanted ->
                holds.hold(wanted.deviceId, until[index])
                queued -= wanted.deviceId
            }
            warned -= RETRY_WARNING
            pump(force = false)
            return
        }
        val after = wait.failed(failure?.reply, deps.now(), deps.jitter)
        requeue(sent)
        forcing = false
        if (warned.add(RETRY_WARNING)) {
            deps.warn("Device licensing failed (${failure?.cause}) and tries again in ${maxOf(after / 1000, 1)} s. The model keeps running. Check that the license server is reachable. See $RUN_ON_A_SERVER_GUIDE")
        }
        arm(after)
    }

    // The local time until which the device needs no request: its license's expiry, or a day for an answer without a license that verifies.
    private fun expiry(token: String?, serverTime: String?, received: Long): Long {
        val (_, end) = verifiedPeriodEnd(token, deps.publicKeys) ?: return received + LICENSE_TERMINAL_WAIT_MS
        val expiry = end - (serverTime?.let(::parseISO8601)?.let { it - received } ?: 0)
        return if (expiry > received) expiry else received + LICENSE_TERMINAL_WAIT_MS
    }

    @Synchronized
    private fun warnOnce(message: String) {
        if (warned.add(message)) deps.warn(message)
    }

    private companion object {
        const val RETRY_WARNING = "retry"
        const val NO_ANSWER = "no answer: the connection failed or timed out"
    }
}
