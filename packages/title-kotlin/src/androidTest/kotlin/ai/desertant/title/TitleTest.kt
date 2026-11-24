package ai.desertant.title

import ai.desertant.emo.Emo
import android.content.Context
import android.system.Os
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class TitleTest {
    @Test fun downloadsAndGeneratesIndependentCards() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val directory = File.createTempFile("title-", ".test", context.cacheDir)
        check(directory.delete() && directory.mkdir())
        try {
            val first = Titles(context, directory.path).use { titles ->
                assertFalse(titles.isDownloaded())
                titles.download()
                assertTrue(titles.isDownloaded())
                val frost = titles.describe(FROST)
                assertTrue("Expected a card for the garden passage: $frost", frost.description.isNotBlank())
                assertTrue("Expected a title about the plants: $frost", frost.title.contains("tomato", ignoreCase = true))
                Emo(context).use { emo ->
                    assertTrue(emo.suggestions("Dinner with friends", limit = 1).isNotEmpty())
                }
                val interview = titles.describe(INTERVIEW)
                assertTrue("Expected a card for the interview: $interview", interview.description.isNotBlank())
                assertTrue("Expected a podcast title: $interview", interview.title.contains("podcast", ignoreCase = true))
                assertEquals(frost, titles.describe(FROST))
                assertFalse(titles.describe(JAPANESE.repeat(300)).isEmpty)
                frost
            }

            withoutHub {
                Titles(context, directory.path).use { cached ->
                    assertTrue(cached.isDownloaded())
                    assertEquals(first, cached.describe(FROST))
                }
                // A caller-provided bundle has no SDK download metadata.
                val local = File(directory, "local")
                File(local, "litert").mkdirs()
                check(File(directory, BUNDLE).renameTo(File(local, BUNDLE)))
                Titles(context, local.path).use { adopted ->
                    assertTrue(adopted.isDownloaded())
                    assertEquals(first, adopted.describe(FROST))
                }
            }
        } finally {
            directory.deleteRecursively()
        }
        Unit
    }

    private suspend fun withoutHub(test: suspend () -> Unit) {
        val key = "DAL_HF_REPO_SUFFIX"
        val previous = Os.getenv(key)
        Os.setenv(key, "-android-test-unavailable", true)
        try {
            test()
        } finally {
            if (previous == null) Os.unsetenv(key) else Os.setenv(key, previous, true)
        }
    }

    private companion object {
        const val BUNDLE = "litert/title.litertlm"
        const val FROST = "The gardener covered the tomato plants with fleece before the overnight frost. " +
            "She removed it after sunrise once the temperature rose above freezing."
        const val INTERVIEW = "A producer explains how she records a two-person podcast. " +
            "She places a microphone in front of each guest and records both voices on separate tracks."
        const val JAPANESE = "市立図書館は来月から日曜日も開館します。利用者はオンラインで本を予約できます。"
    }
}
