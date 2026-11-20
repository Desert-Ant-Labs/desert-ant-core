package ai.desertant.core

import org.json.JSONException
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 37])
class FaceprintSerializationTest {
    @Test fun storedJsonPreservesAllValuesAndTheModelWithoutWrappingBase64() {
        val faceprint = Faceprint.of(FloatArray(128) { (it - 64).toFloat() }, "custom-embedder")
        val json = faceprint.toJson()

        assertFalse(json.getString("data").contains('\n'))
        val restored = Faceprint.fromJson(JSONObject(json.toString()))
        assertEquals(faceprint, restored)
        assertArrayEquals(faceprint.data, restored.data)
        assertEquals("custom-embedder", restored.model)
    }

    @Test fun readsAFixedLittleEndianFloat32Base64Fixture() {
        // float32 values 1, -2 and 0.5, independent of the SDK's encoder.
        val fixture = JSONObject("""{"model":"fixture-v1","data":"AACAPwAAAMAAAAA/"}""")
        val faceprint = Faceprint.fromJson(fixture)

        assertEquals("fixture-v1", faceprint.model)
        assertArrayEquals(floatArrayOf(1f, -2f, 0.5f), faceprint.values, 0f)
        assertEquals(fixture.getString("data"), faceprint.toJson().getString("data"))
    }

    @Test fun missingRequiredFieldsAreRejected() {
        for (json in listOf("""{"model":"face-1"}""", """{"data":"AACAPw=="}""")) {
            assertThrows(JSONException::class.java) { Faceprint.fromJson(JSONObject(json)) }
        }
    }

    @Test fun malformedBase64AndIncompleteFloatPayloadsAreRejected() {
        for (data in listOf("A", "", "AA==", "AAA=")) {
            val json = JSONObject().put("model", "face-1").put("data", data)
            assertThrows(IllegalArgumentException::class.java) { Faceprint.fromJson(json) }
        }
    }
}
