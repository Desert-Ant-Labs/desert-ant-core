package ai.desertant.core.androidtest

import ai.desertant.emo.Emo
import ai.desertant.gist.Gist
import ai.desertant.redact.Redact
import ai.desertant.toxic.Toxic
import ai.desertant.toxic.Label
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.AfterClass
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** All models coexist and initialize normally, including their independent JNI bridges. */
@RunWith(AndroidJUnit4::class)
class UnicodeModelTest {
    companion object {
        internal val context get() = InstrumentationRegistry.getInstrumentation().targetContext
        internal fun directory(model: String) = File(context.cacheDir, "unicode-models/$model")
        private lateinit var emo: Emo
        private lateinit var gist: Gist
        private lateinit var redact: Redact
        private lateinit var toxic: Toxic

        @JvmStatic @BeforeClass fun downloadPinnedModels() = runBlocking {
            withTimeout(600_000) {
                emo = Emo(context, directory("emo").path)
                gist = Gist(context, directory("gist").path)
                redact = Redact(context, directory("redact").path)
                toxic = Toxic(context, directory("toxic").path)
                // A missing weight, grant or credential is a failure, never a skipped test.
                emo.download(); gist.download(); redact.download(); toxic.download()
            }
        }
        @JvmStatic @AfterClass fun closeModels() {
            if (::emo.isInitialized) emo.close()
            if (::gist.isInitialized) gist.close()
            if (::redact.isInitialized) redact.close()
            if (::toxic.isInitialized) toxic.close()
        }
    }

    @Test fun tokenIdsMatchTrainingReferences() {
        for ((model, file, oracle) in listOf(
            Triple("gist", "gist_tokenizer.bin", "gist-sdk-oracle.json"),
            Triple("toxic", "toxic_tokenizer.bin", "toxic_tokenizer_oracle.json"),
        )) {
            val tokenizer = File(directory(model), file).readBytes()
            val cases = fixture(oracle).jsonArray
            assertTrue(cases.isNotEmpty())
            for (row in cases) {
                val c = row.jsonObject
                assertEquals("$model: ${c.text("text")}", c.getValue("ids"), modelCheck("$model.tokens", c.text("text"), tokenizer))
            }
        }
        val tokenizer = File(directory("redact"), "redact_tokenizer.bin").readBytes()
        for ((a, b) in listOf("café" to "cafe\u0301", "Ａ" to "A", "ﬁ" to "fi")) {
            assertEquals(modelCheck("redact.tokens", a, tokenizer), modelCheck("redact.tokens", b, tokenizer))
        }
    }

    @Test fun semanticResultsAndPositionsRemainAcceptable() = runBlocking {
        withTimeout(300_000) {
            withContext(Dispatchers.Default) {
                repeat(2) {
                    val suggestions = emo.suggestions("Pay my bills", limit = 5)
                    assertTrue(suggestions.any { it.emoji in listOf("💰", "💳", "🧾", "🏦", "📄") })
                    assertTrue(suggestions.all { it.confidence.isFinite() && it.confidence in 0.0..1.0 })
                    assertTrue(gist.classify("A one-pan roast chicken recipe for weeknights").any { it.slug == "food-drink" })
                    assertTrue(gist.classify("El equipo gana la final de la copa").any { it.slug == "sports" })
                    assertTrue(gist.scores("How to start a podcast with just your iPhone").values.all { it.isFinite() && it in 0.0..1.0 })
                }
                assertTrue(emo.suggestions("").isEmpty())
                assertTrue(gist.scores("   ").isEmpty())
                val golden = fixture("toxic_golden.json").jsonObject
                val texts = golden.getValue("texts").jsonArray
                assertFalse(toxic.analyze(texts[0].jsonPrimitive.content).isToxic)
                assertTrue(Label.HATEFUL in toxic.analyze(texts[4].jsonPrimitive.content).flagged)

                for (text in listOf(
                    "😀 Email Anna Kovács at anna@example.hu, IBAN DE89370400440532013000.",
                    "👩‍💻 Call Dr. Alice Grant on +49 30 1234567.",
                    "cafe\u0301\u0000 Contact anna@example.hu after the break.",
                )) {
                    val result = redact.redaction(text)
                    for (item in result.items) {
                        assertTrue(item.start >= 0 && item.end <= text.length && item.start < item.end)
                        assertEquals(item.original, text.substring(item.start, item.end))
                    }
                    if (text.contains("anna@example.hu")) {
                        assertTrue(result.items.any { it.label == "EMAIL" && it.original == "anna@example.hu" })
                        assertFalse(result.redactedText.contains("anna@example.hu"))
                    }
                    assertEquals(text, result.restore(result.redactedText))
                }
            }
        }
    }

    @Test fun publicKotlinBoundaryHandlesAdversarialInputs() = runBlocking {
        withTimeout(300_000) {
            for (text in listOf("", "Ａ\u0000ﬁ", "a\uD800z", "a\uDC00z", "مرحبا नमस्ते 你好 𠀀 👩‍💻", "word ".repeat(100))) {
                val repaired = text.toByteArray().decodeToString()
                assertEquals(emo.suggestions(repaired), emo.suggestions(text))
                val scores = gist.scores(text)
                assertTrue(scores.values.all { it.isFinite() && it in 0.0..1.0 })
                assertEquals(gist.scores(repaired), scores)
                val analysis = toxic.analyze(text)
                assertTrue(analysis.scores.values.all { it.isFinite() && it in 0.0..1.0 })
                val redaction = redact.redaction(text)
                assertEquals(repaired, redaction.restore(redaction.redactedText))
                for (item in redaction.items) assertEquals(item.original, repaired.substring(item.start, item.end))
            }
        }
    }
}
