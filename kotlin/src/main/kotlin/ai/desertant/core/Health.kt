package ai.desertant.core

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Process
import java.io.File
import java.util.zip.ZipFile

/**
 * What [Health.issues] judges, gathered from the app by [Health.inputs] so the
 * rules run on the JVM.
 *
 * @property abis the ABIs this process can run, preferred first.
 * @property packaged the native libraries the APKs carry, by ABI.
 * @property installed the libraries extracted for the ABI the installer
 *   picked, for the installs that extract them.
 */
internal data class HealthInputs(
    val abis: List<String>,
    val packaged: Map<String, Set<String>>,
    val installed: Set<String>,
    val apiKey: String?,
    val internetGranted: Boolean,
)

internal object Health {
    const val LITERT = "libLiteRt.so"
    const val GPU_ACCELERATOR = "libLiteRtClGlAccelerator.so"

    /** Each model SDK's JNI library (`libEyeAndroid.so`, ...). */
    private val modelLibrary = Regex("""lib[A-Z][A-Za-z]*Android\.so""")
    private val apkLibrary = Regex("""lib/([^/]+)/([^/]+\.so)""")

    /**
     * The ABI the installer chose: the first this process runs that the APKs
     * carry any library for, as the package manager picks it.
     */
    fun processAbi(inputs: HealthInputs): String? =
        inputs.abis.firstOrNull { inputs.packaged[it].orEmpty().isNotEmpty() } ?: inputs.abis.firstOrNull()

    fun issues(inputs: HealthInputs): List<String> = buildList {
        val abi = processAbi(inputs) ?: "this device"
        val available = inputs.packaged[abi].orEmpty() + inputs.installed
        if (LITERT !in available) {
            add("$LITERT not found for $abi: no model can load. It ships in ai.desertant:core; check for a packaging exclude.")
        }
        inputs.packaged.filterKeys { it != abi }.values.flatten()
            .filter { modelLibrary.matches(it) && it !in available }
            .toSortedSet()
            .forEach { library ->
                val others = inputs.packaged.filterValues { library in it }.keys.sorted().joinToString()
                add("$library is packaged for $others but not for $abi, the ABI this app runs: that model cannot load.")
            }
        if (GPU_ACCELERATOR !in available) {
            add("$GPU_ACCELERATOR not found for $abi: GPU acceleration unavailable, models run on CPU.")
        }
        if (inputs.apiKey.isNullOrBlank()) {
            add("No API key. Call DesertAnt.configure(apiKey) to send a key with license requests.")
        }
        if (!inputs.internetGranted) {
            add("The INTERNET permission is missing: models cannot download and licenses cannot be requested.")
        }
    }

    /** The app's side of [HealthInputs]. Reads the APKs' zip directories. */
    fun inputs(context: Context): HealthInputs {
        val info = context.applicationInfo
        val packaged = mutableMapOf<String, MutableSet<String>>()
        // Split APKs too: an app bundle puts the native libraries in a
        // per-ABI config split, not in the base APK.
        for (apk in listOfNotNull(info.sourceDir) + info.splitSourceDirs.orEmpty()) {
            try {
                ZipFile(apk).use { zip ->
                    for (entry in zip.entries()) {
                        val match = apkLibrary.matchEntire(entry.name) ?: continue
                        packaged.getOrPut(match.groupValues[1]) { mutableSetOf() }.add(match.groupValues[2])
                    }
                }
            } catch (_: java.io.IOException) {
                // An APK this process cannot read adds nothing; the checks then
                // report what is missing from the rest.
            }
        }
        val installed = info.nativeLibraryDir?.let { File(it).list() }.orEmpty()
            .filterTo(mutableSetOf()) { it.endsWith(".so") }
        val abis = if (Process.is64Bit()) Build.SUPPORTED_64_BIT_ABIS else Build.SUPPORTED_32_BIT_ABIS
        return HealthInputs(
            abis = abis.toList(),
            packaged = packaged,
            installed = installed,
            apiKey = DesertAnt.currentApiKey,
            internetGranted = context.checkSelfPermission(Manifest.permission.INTERNET) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
}
