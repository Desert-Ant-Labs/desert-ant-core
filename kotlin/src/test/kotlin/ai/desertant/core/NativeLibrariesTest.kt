package ai.desertant.core

import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeLibrariesTest {
    @Test fun rejectsMismatchedKotlinBeforeLoadingTheNativeLibrary() {
        val error = assertThrows(IllegalStateException::class.java) {
            NativeLibraries.loadModel("EmoAndroid", "0.0.1") {
                error("The version check must precede JNI")
            }
        }
        assertTrue(error.message.orEmpty().contains("model artifact 0.0.1, core ${SDK_VERSION}"))
        assertTrue(error.message.orEmpty().contains("ai.desertant:bom"))
    }

    @Test fun reportsBothVersionsForAMismatchedNativeLibrary() {
        val error = assertThrows(IllegalStateException::class.java) {
            requireSdkVersion("EmoAndroid", "native library", "4.1.0", "4.2.0")
        }
        assertTrue(error.message.orEmpty().contains("EmoAndroid: native library 4.1.0, core 4.2.0"))
    }
}
