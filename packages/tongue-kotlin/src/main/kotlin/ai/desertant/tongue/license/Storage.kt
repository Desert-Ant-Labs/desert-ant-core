package ai.desertant.tongue.license

import java.io.File
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.util.Properties

// The install id key and, on Android, the file are the core's, so an app with both has one install id.
internal const val INSTALL_ID_KEY = "ai.desertant.usage.deviceId"
internal const val ANDROID_PREFERENCES_FILE = "desert-ant"

// Not under the core's "ai.desertant.license." prefix: the core's record lists the models it activated.
internal fun licenseStorageKey(namespace: String): String = "ai.desertant.tongue.license.$namespace"

internal interface LicenseStore {
    fun get(key: String): String?
    fun set(key: String, value: String)

    /** The stored value, or the made one after it is stored. What another writer stored in between wins. */
    fun getOrSet(key: String, make: () -> String): String {
        get(key)?.takeIf { it.isNotEmpty() }?.let { return it }
        val made = make()
        set(key, made)
        return get(key)?.takeIf { it.isNotEmpty() } ?: made
    }
}

internal class MemoryStore : LicenseStore {
    private val values = HashMap<String, String>()

    @Synchronized
    override fun get(key: String): String? = values[key]

    @Synchronized
    override fun set(key: String, value: String) {
        values[key] = value
    }

    @Synchronized
    override fun getOrSet(key: String, make: () -> String): String = super.getOrSet(key, make)
}

// SharedPreferences through reflection, so the jar compiles and runs with no Android classes.
internal class AndroidPreferencesStore private constructor(private val preferences: Any) : LicenseStore {
    private val getString = Class.forName("android.content.SharedPreferences")
        .getMethod("getString", String::class.java, String::class.java)
    private val edit = Class.forName("android.content.SharedPreferences").getMethod("edit")
    private val putString = Class.forName("android.content.SharedPreferences\$Editor")
        .getMethod("putString", String::class.java, String::class.java)
    private val apply = Class.forName("android.content.SharedPreferences\$Editor").getMethod("apply")

    override fun get(key: String): String? = try {
        (getString.invoke(preferences, key, null) as String?)?.takeIf { it.isNotEmpty() }
    } catch (_: Exception) {
        null
    }

    override fun set(key: String, value: String) {
        try {
            apply.invoke(putString.invoke(edit.invoke(preferences), key, value))
        } catch (_: Exception) {
        }
    }

    companion object {
        // Null off Android, for an object that is no Context, and before the first unlock of a credential-protected one.
        fun forContext(context: Any?): LicenseStore? = try {
            val type = Class.forName("android.content.Context")
            if (!type.isInstance(context)) {
                null
            } else {
                val preferences = type.getMethod("getSharedPreferences", String::class.java, Int::class.javaPrimitiveType)
                    .invoke(context, ANDROID_PREFERENCES_FILE, 0)
                preferences?.let(::AndroidPreferencesStore)
            }
        } catch (_: Exception) {
            null
        } catch (_: LinkageError) {
            null
        }

        fun packageName(context: Any?): String? = try {
            val type = Class.forName("android.content.Context")
            if (type.isInstance(context)) type.getMethod("getPackageName").invoke(context) as? String else null
        } catch (_: Exception) {
            null
        } catch (_: LinkageError) {
            null
        }
    }
}

/** The directory of the license file on a JVM: `DAL_STATE_DIR`, else the user's config directory. */
internal fun stateDirectory(environment: (String) -> String?, home: String?): File? {
    environment("DAL_STATE_DIR")?.takeIf { it.isNotEmpty() }?.let { return File(it) }
    environment("XDG_CONFIG_HOME")?.takeIf { it.isNotEmpty() }?.let { return File(it, "desert-ant") }
    // "?" is what a JVM reports for a user with no home directory.
    return home?.takeIf { it.isNotEmpty() && it != "?" }?.let { File(File(it, ".config"), "desert-ant") }
}

/** One properties file, shared by the processes of a host. What it cannot write it keeps in memory, and it warns once. */
internal class FileStore(
    directory: File?,
    private val warn: (String) -> Unit,
    private val lockWaitMs: Long = 3_000,
) : LicenseStore {
    private val file = directory?.let { File(it, "tongue.properties") }
    private val unsaved = Properties()
    private var warned = false

    override fun get(key: String): String? = synchronized(processLock) { current().getProperty(key) }

    override fun set(key: String, value: String) {
        locked { write(key, value) }
    }

    override fun getOrSet(key: String, make: () -> String): String = locked {
        current().getProperty(key)?.takeIf { it.isNotEmpty() } ?: make().also { write(key, it) }
    }

    // The file lock is for other processes, and the JVM refuses a second one from this process, so threads take processLock first.
    private fun <T> locked(body: () -> T): T = synchronized(processLock) {
        var channel: FileChannel? = null
        var lock: FileLock? = null
        try {
            val directory = file?.parentFile?.toPath()
            if (directory != null) {
                Files.createDirectories(directory)
                channel = FileChannel.open(directory.resolve("tongue.lock"), StandardOpenOption.CREATE, StandardOpenOption.WRITE)
                lock = lockWithin(channel)
            }
        } catch (_: Exception) {
        }
        try {
            body()
        } finally {
            try {
                lock?.release()
            } catch (_: Exception) {
            }
            try {
                channel?.close()
            } catch (_: Exception) {
            }
        }
    }

    // Bounded: a holder that never lets go must not stop the license thread. Without the lock the write still happens.
    private fun lockWithin(channel: FileChannel): FileLock? {
        var waited = 0L
        while (true) {
            val lock = try {
                channel.tryLock()
            } catch (_: OverlappingFileLockException) {
                null
            }
            if (lock != null || waited >= lockWaitMs) return lock
            Thread.sleep(LOCK_POLL_MS)
            waited += LOCK_POLL_MS
        }
    }

    private fun current(): Properties {
        val read = Properties()
        try {
            if (file != null && file.isFile) file.inputStream().use(read::load)
        } catch (_: IllegalArgumentException) {
            // A file that does not parse is replaced by the next write, or every process would make a new install id.
            read.clear()
        } catch (_: Exception) {
            read.clear()
            warnOnce()
        }
        // An install id another process stored wins over one this process could not write.
        if (!read.getProperty(INSTALL_ID_KEY).isNullOrEmpty()) unsaved.remove(INSTALL_ID_KEY)
        read.putAll(unsaved)
        return read
    }

    private fun write(key: String, value: String) {
        val values = current()
        values.setProperty(key, value)
        try {
            val target = (file ?: throw IOException("no directory")).toPath()
            Files.createDirectories(target.parent)
            val draft = Files.createTempFile(target.parent, "tongue", ".tmp")
            try {
                Files.newOutputStream(draft).use { values.store(it, null) }
                try {
                    Files.move(draft, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
                } catch (_: AtomicMoveNotSupportedException) {
                    Files.move(draft, target, StandardCopyOption.REPLACE_EXISTING)
                }
            } finally {
                Files.deleteIfExists(draft)
            }
            unsaved.clear()
        } catch (_: Exception) {
            // Kept for the next write, which tries the file again.
            unsaved.setProperty(key, value)
            warnOnce()
        }
    }

    private fun warnOnce() {
        if (warned) return
        warned = true
        warn("Tongue cannot keep its license in ${file ?: "a file (no home directory)"}, so it may ask again in each process. Set DAL_STATE_DIR to a directory the process can write.")
    }

    private companion object {
        val processLock = Any()
        const val LOCK_POLL_MS = 50L
    }
}

internal fun isAndroid(): Boolean =
    System.getProperty("java.vm.vendor")?.contains("Android", ignoreCase = true) == true ||
        System.getProperty("java.runtime.name")?.contains("Android", ignoreCase = true) == true
