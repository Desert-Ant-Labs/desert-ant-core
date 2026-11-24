package ai.desertant.tongue.license

import java.util.UUID

internal data class StoredLicense(
    val token: String? = null,
    val licenseId: String? = null,
    val period: String? = null,
    val activatedModels: List<String>? = null,
    val refusedAt: Map<String, Long>? = null,
    val serverOffset: Long = 0,
) {
    fun dropToken(): StoredLicense = copy(token = null, licenseId = null, period = null, activatedModels = null)

    fun isRefused(model: String, time: Long): Boolean {
        val refused = refusedAt?.get(model) ?: return false
        return time >= refused && time - refused < LICENSE_TERMINAL_WAIT_MS
    }

    fun refuse(model: String, time: Long): StoredLicense = copy(refusedAt = (refusedAt ?: emptyMap()) + (model to time))

    fun dropEndedRefusals(time: Long): StoredLicense {
        val waits = refusedAt?.filter { isRefused(it.key, time) } ?: return this
        return copy(refusedAt = waits.ifEmpty { null })
    }

    fun encode(): String {
        val fields = ArrayList<String>()
        token?.let { fields += "\"token\":${Json.quote(it)}" }
        licenseId?.let { fields += "\"licenseId\":${Json.quote(it)}" }
        period?.let { fields += "\"period\":${Json.quote(it)}" }
        activatedModels?.let { models -> fields += "\"activatedModels\":[${models.joinToString(",") { Json.quote(it) }}]" }
        refusedAt?.let { waits ->
            fields += "\"refusedAt\":{${waits.entries.joinToString(",") { "${Json.quote(it.key)}:${it.value}" }}}"
        }
        fields += "\"serverOffset\":$serverOffset"
        return fields.joinToString(",", "{", "}")
    }

    companion object {
        fun decode(json: String?): StoredLicense {
            val fields = json?.let(Json::parseObject) ?: return StoredLicense()
            return try {
                StoredLicense(
                    token = fields["token"] as String?,
                    licenseId = fields["licenseId"] as String?,
                    period = fields["period"] as String?,
                    activatedModels = (fields["activatedModels"] as List<*>?)?.map { it as String },
                    refusedAt = (fields["refusedAt"] as Map<*, *>?)?.entries?.associate { it.key as String to it.value as Long },
                    serverOffset = fields["serverOffset"] as Long? ?: 0,
                )
            } catch (_: ClassCastException) {
                StoredLicense()
            } catch (_: NullPointerException) {
                StoredLicense()
            }
        }
    }
}

private val licenseRecordLock = Any()

internal class LicenseDeps(
    val store: () -> LicenseStore,
    val identity: () -> LicenseIdentity,
    val secret: () -> String?,
    val endpoint: () -> String,
    val post: (url: String, body: ByteArray, apiKey: String?) -> HttpReply? = ::httpPost,
    val now: () -> Long = System::currentTimeMillis,
    val jitter: (Long) -> Long = { kotlin.random.Random.nextLong(0, it + 1) },
    val publicKeys: Map<String, String> = licensePublicKeys,
    val warn: (String) -> Unit = LicenseHost::warn,
    val keepsLicenses: () -> Boolean = { true },
    val coreIsPresent: () -> Boolean = { false },
    val sleep: (Long) -> Unit = Thread::sleep,
) {
    fun send(path: String, body: ByteArray, who: LicenseIdentity): HttpReply? = try {
        post(endpoint().trimEnd('/') + "/" + path, body, who.apiKey)
    } catch (_: Throwable) {
        null
    }
}

/** The license of this install. Every method runs on the one license thread. */
internal class InstallLicenseClient(
    private val deps: LicenseDeps,
    private val schedule: (delayMs: Long, work: () -> Unit) -> Unit,
) {
    private enum class Outcome { SETTLED, NETWORK, BACKOFF }

    private val wanted = HashSet<String>()
    private val waiting = HashSet<String>()
    private val attempts = HashMap<String, Int>()
    private val unsaved = HashMap<String, Pair<String, String?>>()
    private var retryAfter: Long? = null
    // Kept in memory: a store that drops writes would otherwise make a new install id, and a new license, for each request.
    private var installId: String? = null
    private var warnedNoStore = false

    fun modelLoaded() {
        val who = deps.identity()
        if (who.platform == "android" && !deps.keepsLicenses()) {
            if (!warnedNoStore) {
                warnedNoStore = true
                deps.warn("Tongue was loaded without a usable Context, so it has nowhere to keep a license and asks for none. Pass the Context to Tongue.bundled.")
            }
            return
        }
        wanted += who.namespace
        work(who)
    }

    private fun work(who: LicenseIdentity) {
        val slot = who.namespace
        // A server with a device id secret licenses the devices it serves, and not itself.
        if (who.platform == "server" && deps.secret() != null) {
            wanted -= slot
            return
        }
        if (slot in waiting || slot !in wanted) return
        val delay = when (advance(who)) {
            Outcome.SETTLED -> {
                wanted -= slot
                return
            }
            Outcome.NETWORK -> LICENSE_NETWORK_RETRY_MS
            Outcome.BACKOFF -> {
                val attempt = attempts[slot] ?: 0
                attempts[slot] = attempt + 1
                licenseBackoff(attempt, retryAfter, deps.jitter)
            }
        }
        waiting += slot
        schedule(delay) { retry(slot) }
    }

    private fun retry(slot: String) {
        waiting -= slot
        val who = deps.identity()
        if (who.namespace != slot && wanted.remove(slot)) {
            wanted += who.namespace
            attempts -= slot
        }
        work(who)
    }

    private fun advance(who: LicenseIdentity): Outcome {
        if (load(who).isRefused(MODEL_ID, deps.now())) return Outcome.SETTLED
        if (replaceUnlessValid(who) { it }.second) return Outcome.SETTLED
        return grant(who)
    }

    // The core shares the store but no lock, so two ids are still possible when both create one at the same moment.
    private fun currentInstallId(): String {
        val store = deps.store()
        if (store.get(INSTALL_ID_KEY).isNullOrEmpty() && deps.coreIsPresent()) {
            var waited = 0L
            while (waited < CORE_INSTALL_ID_WAIT_MS && store.get(INSTALL_ID_KEY).isNullOrEmpty()) {
                deps.sleep(CORE_INSTALL_ID_POLL_MS)
                waited += CORE_INSTALL_ID_POLL_MS
            }
        }
        return store.getOrSet(INSTALL_ID_KEY) { installId ?: UUID.randomUUID().toString() }.also { installId = it }
    }

    private fun grant(who: LicenseIdentity): Outcome {
        val reply = deps.send("license", grantBody(currentInstallId(), who), who) ?: return Outcome.NETWORK
        val received = deps.now()
        retryAfter = licenseRetryAfter(reply)
        when (licenseResponseAction(reply.status, reply.body)) {
            LicenseResponseAction.DONE -> {}
            LicenseResponseAction.TERMINAL -> {
                replaceUnlessValid(who) { it.refuse(MODEL_ID, received) }
                return Outcome.SETTLED
            }
            LicenseResponseAction.RETRY -> return Outcome.BACKOFF
            LicenseResponseAction.RETRY_NETWORK -> return Outcome.NETWORK
        }
        val (token, serverTime) = grantAnswer(reply.body) ?: return Outcome.BACKOFF
        val offset = serverTime?.let(::parseISO8601)?.let { it - received } ?: 0
        val usable = LicenseToken.parse(token)?.takeIf { isValid(StoredLicense(token = token, serverOffset = offset)) }
        if (usable != null) attempts -= who.namespace
        replaceUnlessValid(who) { license ->
            if (usable == null) {
                license.refuse(MODEL_ID, received)
            } else {
                license.copy(
                    token = token,
                    licenseId = usable.licenseId,
                    period = usable.period,
                    activatedModels = listOf(MODEL_ID),
                    serverOffset = offset,
                    refusedAt = license.refusedAt?.minus(MODEL_ID),
                )
            }
        }
        return Outcome.SETTLED
    }

    // Other clients write this record too, so a write starts from what is stored now.
    private fun replaceUnlessValid(
        who: LicenseIdentity, change: (StoredLicense) -> StoredLicense,
    ): Pair<StoredLicense, Boolean> {
        val key = licenseStorageKey(who.namespace)
        while (true) {
            val raw = read(key)
            val stored = StoredLicense.decode(raw)
            if (isValid(stored)) return stored to true
            val license = change(stored.dropToken()).dropEndedRefusals(deps.now())
            val saved = synchronized(licenseRecordLock) {
                if (read(key) != raw) {
                    false
                } else {
                    if (license != stored) save(license, key)
                    true
                }
            }
            if (saved) return license to false
        }
    }

    // The copy in memory serves only while the store holds what it held when the write failed.
    private fun read(key: String): String? {
        val kept = deps.store().get(key)
        val copy = unsaved[key] ?: return kept
        if (kept == copy.second) return copy.first
        unsaved -= key
        return kept
    }

    private fun load(who: LicenseIdentity): StoredLicense = StoredLicense.decode(read(licenseStorageKey(who.namespace)))

    private fun save(license: StoredLicense, key: String) {
        val json = license.dropEndedRefusals(deps.now()).encode()
        val store = deps.store()
        store.set(key, json)
        val kept = store.get(key)
        if (kept == json) unsaved -= key else unsaved[key] = json to kept
    }

    private fun isValid(license: StoredLicense): Boolean {
        val (token, end) = verifiedPeriodEnd(license.token, deps.publicKeys) ?: return false
        val serverNow = deps.now() + license.serverOffset
        return serverNow / 1000 >= token.issuedAt && serverNow < end
    }
}
