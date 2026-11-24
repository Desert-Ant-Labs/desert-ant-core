package ai.desertant.core.androidtest

import ai.desertant.DesertAntNative
import ai.desertant.tongue.runGoldenVectors
import android.icu.lang.UCharacter
import android.icu.util.VersionInfo
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

internal fun fixture(name: String): JsonElement = Json.parseToJsonElement(
    InstrumentationRegistry.getInstrumentation().context.assets.open(name).bufferedReader().use { it.readText() }
)
internal fun JsonObject.text(key: String): String = getValue(key).jsonPrimitive.content
internal fun core(operation: String, input: String): String = CoreBridge.unicode(
    DesertAntNative::class.java, operation.toByteArray(), input.toByteArray(Charsets.UTF_8)
).toString(Charsets.UTF_8)
internal fun modelCheck(operation: String, text: String, artifact: ByteArray = byteArrayOf()): JsonElement =
    Json.parseToJsonElement(UnicodeBridge.check(DesertAntNative::class.java, operation.toByteArray(), text.toByteArray(), artifact).decodeToString())

@RunWith(AndroidJUnit4::class)
class UnicodeCompatibilityTest {
    @Test fun primitivesAndExplicitVersionDifferences() {
        val root = fixture("primitives.json").jsonObject
        assertEquals(1, root.getValue("schema").jsonPrimitive.int)
        val cases = root.getValue("cases").jsonArray
        assertTrue(cases.isNotEmpty())
        val previous = Locale.getDefault()
        try {
            // Locale must not change the model's features.
            for (locale in listOf(Locale.US, Locale.forLanguageTag("tr-TR"))) {
                Locale.setDefault(locale)
                for (row in cases) {
                    val c = row.jsonObject
                    assertEquals(c.text("name"), c.text("expected"), core(c.text("operation"), c.text("input")))
                }
            }
        } finally { Locale.setDefault(previous) }
        for (row in root.getValue("exceptions").jsonArray) {
            val c = row.jsonObject
            val expected = if (UCharacter.getUnicodeVersion().major < c.getValue("unicodeMajorBefore").jsonPrimitive.int)
                c.text("before") else c.text("after")
            assertEquals(c.text("name"), expected, core(c.text("operation"), c.text("input")))
        }
        val runtime = buildJsonObject {
            put("api", Build.VERSION.SDK_INT)
            put("abi", Build.SUPPORTED_ABIS.first())
            put("icu", VersionInfo.ICU_VERSION.toString())
            put("unicode", UCharacter.getUnicodeVersion().toString())
            put("documentedDifferences", root.getValue("exceptions"))
        }.toString()
        // The report must not depend on a separate, asynchronously captured log stream.
        InstrumentationRegistry.getInstrumentation().sendStatus(2, Bundle().apply {
            putString("dalUnicodeRuntime", runtime)
        })
        Log.i("DAL_UNICODE", runtime)
    }

    @Test fun primitiveBridgeHandlesAdversarialTextAndWorkerThreads() {
        val worker = Executors.newSingleThreadExecutor()
        try {
            val future = worker.submit<Unit> {
                for (text in listOf("", "a\u0000Ａ", "a\uD800z", "a\uDC00z", "👩‍💻".repeat(2000), "e\u0301".repeat(10000))) {
                    // The public Kotlin boundary repairs malformed UTF-16 when encoding UTF-8.
                    val repaired = text.toByteArray().toString(Charsets.UTF_8)
                    val expected = java.text.Normalizer.normalize(repaired, java.text.Normalizer.Form.NFKC)
                    repeat(3) { assertEquals(expected, core("nfkc", text)) }
                    assertEquals(expected, core("nfkc", core("nfkc", text)))
                }
                assertEquals("before|after", core("words", "before\u0000after"))
            }
            future.get(45, TimeUnit.SECONDS)
        } finally { worker.shutdownNow() }
    }

    @Test fun speechWordFoldingRetainsItsContract() {
        for ((upper, lower) in listOf("STRASSE" to "straße", "ΟΣ" to "ος", "ÉPISODE" to "épisode", "ЭПИЗОД" to "эпизод")) {
            assertEquals(modelCheck("voz.fold", upper), modelCheck("voz.fold", lower))
        }
        assertNotEquals(modelCheck("voz.fold", "résumé"), modelCheck("voz.fold", "resume"))
        assertEquals(JsonPrimitive("hello world"), modelCheck("voz.detokenize", "▁hello▁world▁"))
    }

    @Test fun tongueGoldenVectorsRunOnAndroid() {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        runGoldenVectors { name -> assets.open(name).bufferedReader().use { it.readText() } }
    }

    @Test fun frozenEmoFeaturesAndGistLexicalFeatures() {
        val cases = fixture("emo-features.json").jsonObject.getValue("cases").jsonArray
        assertTrue(cases.isNotEmpty())
        for (row in cases) {
            val c = row.jsonObject
            assertEquals(c.text("input"), c.getValue("features"), modelCheck("emo.features", c.text("input")))
        }
        val oracle = fixture("gist-feature-oracle.json").jsonArray
        assertTrue(oracle.isNotEmpty())
        for (row in oracle) {
            val c = row.jsonObject
            val got = modelCheck("gist.features", c.text("text")).jsonArray
            val expected = c.getValue("ngram_nz").jsonObject
            assertEquals(expected.size, got.count { it.jsonPrimitive.double != 0.0 })
            for ((index, value) in expected) assertEquals(value.jsonPrimitive.double, got[index.toInt()].jsonPrimitive.double, 1e-6)
        }
    }

    @Test fun redactDeterministicReferenceCorpus() {
        val oracle = fixture("deterministic_corpus.json").jsonArray
        assertTrue(oracle.isNotEmpty())
        assertTrue(oracle.size > 1000)
        val failures = mutableListOf<String>()
        for (row in oracle) {
            val c = row.jsonObject
            val expected = c.getValue("py").jsonArray.toSet()
            val got = modelCheck("redact.spans", c.text("text")).jsonArray.toSet()
            if (expected != got) failures += "${c.text("text")}: expected $expected, got $got"
        }
        assertTrue("${failures.size} mismatches: ${failures.take(10)}", failures.isEmpty())
    }
}

/** Each invocation gets a new instrumentation process, with one model selected by the runner. */
@RunWith(AndroidJUnit4::class)
class NativeLibraryCompatibilityTest {
    @Test fun loadsShippingLibrary() {
        val library = InstrumentationRegistry.getArguments().getString("nativeLibrary")
            ?: error("nativeLibrary argument is required")
        System.loadLibrary("LiteRt")
        System.loadLibrary(library)
        System.loadLibrary(library)
    }
}
