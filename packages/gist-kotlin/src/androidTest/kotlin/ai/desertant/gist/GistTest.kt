package ai.desertant.gist

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented tests for the Android binding, exercising the real on-device path
 * via JNI: platform JSON via CHostBridge, LiteRT inference, and the
 * static-stdlib runtime. No model ships with the AAR, so the model is downloaded
 * into the instrumentation app's cache on the first run and reused afterward.
 */
@RunWith(AndroidJUnit4::class)
class GistTest {
    private lateinit var gist: Gist

    @Before fun setUp() {
        gist = Gist(ApplicationProvider.getApplicationContext())
        runBlocking { gist.download() }   // fetch once up front; cached afterward
    }
    // Null-safe: if setUp() throws, an unguarded close() replaces the real
    // failure with UninitializedPropertyAccessException and hides the cause.
    @After fun tearDown() { if (::gist.isInitialized) gist.close() }

    @Test fun classifiesEnglishText() = runTest {
        val topics = gist.classify("A one-pan roast chicken recipe for weeknights")
        assertTrue("expected topics", topics.isNotEmpty())
        assertTrue("got ${topics.map { it.slug }}", topics.any { it.slug == "food-drink" })
        assertTrue("every topic needs a display name", topics.all { it.name.isNotEmpty() })
    }

    @Test fun classifiesMultilingualText() = runTest {
        val topics = gist.classify("El equipo gana la final de la copa")
        assertTrue("got ${topics.map { it.slug }}", topics.any { it.slug == "sports" })
    }

    @Test fun scoresCoverTheTaxonomy() = runTest {
        val scores = gist.scores("How to start a podcast with just your iPhone")
        assertEquals(36, scores.size)
        assertTrue(scores.values.all { it in 0.0..1.0 })
    }

    @Test fun ranksByScoreAndRespectsTopK() = runTest {
        val topics = gist.classify("How to start a podcast with just your iPhone", topK = 5)
        assertTrue(topics.size <= 5)
        assertEquals(topics.map { it.score }.sortedDescending(), topics.map { it.score })
    }

    /** The top topic comes back even when nothing clears the threshold. */
    @Test fun alwaysReturnsTheTopTopic() = runTest {
        assertEquals(1, gist.classify("asdfgh qwerty", threshold = 0.99).size)
    }

    @Test fun emptyInputReturnsEmpty() = runTest {
        assertTrue(gist.classify("   ").isEmpty())
        assertTrue(gist.scores("").isEmpty())
    }

    /** The roll-up is pure Kotlin, so it needs no model — but it must agree with
     *  the Swift and JS implementations on the same posts. */
    @Test fun channelRollupRanksByShare() {
        val posts = listOf(
            PostTopics(mapOf("food-drink" to 0.9, "travel" to 0.2)),
            PostTopics(mapOf("food-drink" to 0.8)),
            PostTopics(mapOf("food-drink" to 0.7, "travel" to 0.3)),
        )
        val rolled = channelTopics(posts)
        assertEquals("food-drink", rolled[0].slug)
        assertEquals(3, rolled[0].postCount)
        assertTrue(rolled[0].share > 0.5)
    }

    @Test fun channelRollupNeedsMinPosts() {
        val one = listOf(PostTopics(mapOf("travel" to 0.9)))
        assertTrue(channelTopics(one).isEmpty())
        assertEquals(1, channelTopics(one, RollupOptions(minPosts = 1)).size)
    }
}
