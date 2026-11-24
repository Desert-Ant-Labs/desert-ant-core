package ai.desertant.consumer.handshake

import ai.desertant.emo.Emo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HandshakeTest {
    @Test fun constructsEmoOrReportsTheVersionMismatch() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val expected = InstrumentationRegistry.getArguments().getString("expectedMismatch")
        if (expected == null) {
            Emo(context).use { }
        } else {
            val error = assertThrows(IllegalStateException::class.java) { Emo(context).use { } }
            assertEquals(
                "Desert Ant SDK version mismatch for EmoAndroid: $expected. " +
                    "Align all ai.desertant dependencies with ai.desertant:bom.",
                error.message,
            )
        }
    }
}
