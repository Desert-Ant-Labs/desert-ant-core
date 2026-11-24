package ai.desertant.core

import org.junit.Assert.assertEquals
import org.junit.Test

class HealthTest {
    private val core = setOf(Health.LITERT, Health.GPU_ACCELERATOR)

    private fun inputs(
        abis: List<String> = listOf("arm64-v8a"),
        packaged: Map<String, Set<String>> = mapOf("arm64-v8a" to core + "libEyeAndroid.so"),
        installed: Set<String> = emptySet(),
        apiKey: String? = "dal_key",
        internetGranted: Boolean = true,
    ) = HealthInputs(abis, packaged, installed, apiKey, internetGranted)

    @Test fun aWellConfiguredAppHasNoIssues() {
        assertEquals(emptyList<String>(), Health.issues(inputs()))
    }

    @Test fun reportsTheMissingGpuAcceleratorInOneLine() {
        val issues = Health.issues(inputs(packaged = mapOf("arm64-v8a" to setOf(Health.LITERT, "libEyeAndroid.so"))))
        assertEquals(
            listOf("libLiteRtClGlAccelerator.so not found for arm64-v8a: GPU acceleration unavailable, models run on CPU."),
            issues,
        )
    }

    /** An x86_64 emulator that translates arm64 installs an arm64-only APK as arm64. */
    @Test fun theAbiIsTheFirstTheApkCarries() {
        val issues = Health.issues(inputs(abis = listOf("x86_64", "arm64-v8a")))
        assertEquals(emptyList<String>(), issues)
    }

    @Test fun anApkBuiltForAnotherAbiCannotLoad() {
        val issues = Health.issues(inputs(abis = listOf("x86_64")))
        assertEquals(
            listOf(
                "libLiteRt.so not found for x86_64: no model can load. It ships in ai.desertant:core; check for a packaging exclude.",
                "libEyeAndroid.so is packaged for arm64-v8a but not for x86_64, the ABI this app runs: that model cannot load.",
                "libLiteRtClGlAccelerator.so not found for x86_64: GPU acceleration unavailable, models run on CPU.",
            ),
            issues,
        )
    }

    @Test fun oneModelMissingAnAbiIsNamed() {
        val packaged = mapOf(
            "arm64-v8a" to core + setOf("libEyeAndroid.so", "libVozAndroid.so"),
            "x86_64" to core + "libEyeAndroid.so",
        )
        val issues = Health.issues(inputs(abis = listOf("x86_64", "arm64-v8a"), packaged = packaged))
        assertEquals(
            listOf("libVozAndroid.so is packaged for arm64-v8a but not for x86_64, the ABI this app runs: that model cannot load."),
            issues,
        )
    }

    /** An install that extracts its libraries counts what it extracted. */
    @Test fun extractedLibrariesCount() {
        val issues = Health.issues(inputs(packaged = emptyMap(), installed = core))
        assertEquals(emptyList<String>(), issues)
    }

    @Test fun reportsAMissingKeyAndPermission() {
        assertEquals(
            listOf(
                "No API key. Call DesertAnt.configure(apiKey) to send a key with license requests.",
                "The INTERNET permission is missing: models cannot download and licenses cannot be requested.",
            ),
            Health.issues(inputs(apiKey = " ", internetGranted = false)),
        )
    }
}
