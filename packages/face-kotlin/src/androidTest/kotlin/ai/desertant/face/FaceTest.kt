package ai.desertant.face

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class FaceTest {
    private lateinit var face: Face
    private val assets = InstrumentationRegistry.getInstrumentation().context.assets
    private val golden by lazy { JSONObject(assets.open("face_golden.json").bufferedReader().readText()).getJSONObject("photos") }

    private val context get() = ApplicationProvider.getApplicationContext<android.content.Context>()

    /** A local export (FACE_MODEL_DIR) when the assets hold one, else the managed cache. */
    private val directory by lazy {
        if ("face.tflite" in assets.list("").orEmpty()) {
            File(context.cacheDir, "face-local").apply {
                mkdirs()
                for (name in listOf("face_detect.tflite", "face.tflite")) {
                    assets.open(name).use { src -> File(this, name).outputStream().use { src.copyTo(it) } }
                }
            }.path
        } else null
    }

    @Before fun setUp() {
        face = Face(context, directory)
        runBlocking { face.download() }
    }

    @After fun tearDown() { if (::face.isInitialized) face.close() }

    private fun photo(name: String): Triple<ByteArray, Int, Int> {
        val b = assets.open("$name.rgb").readBytes()
        val h = ByteBuffer.wrap(b, 0, 8).order(ByteOrder.LITTLE_ENDIAN)
        val width = h.int
        val height = h.int
        return Triple(b.copyOfRange(8, 8 + width * height * 3), width, height)
    }

    private suspend fun faces(name: String, options: Options = Options.RECOGNITION): List<DetectedFace> {
        val (rgb, w, h) = photo(name)
        return face.faces(rgb, w, h, options)
    }

    private fun noisy(person: Int, seed: Int): DetectedFace {
        val r = java.util.Random(seed.toLong())
        val v = FloatArray(128) { ((r.nextDouble() - 0.5) * 0.18).toFloat() }
        v[person] += 1f
        return DetectedFace(Box(0.1, 0.1, 0.3, 0.3), emptyList(), 0.9, Faceprint.of(v))
    }

    @Test fun faceprintsCompareByCosine() {
        val a = Faceprint.of(FloatArray(128).also { it[0] = 3f; it[1] = 4f })
        val b = Faceprint.of(FloatArray(128).also { it[0] = 4f; it[1] = 3f })
        assertTrue(abs(a.similarity(b) - 0.96) < 1e-6)
        assertTrue(a.isSamePerson(b, Level.STRICT))
        assertTrue(!a.isSamePerson(Faceprint.of(b.values, "face-0")))
        assertEquals(512, a.data.size)
        assertEquals(a, Faceprint.fromJson(a.toJson()))
        assertEquals(listOf(0), Face.matches(a, listOf(a, Faceprint.of(FloatArray(128).also { it[9] = 1f }))).map { it.first })
    }

    @Test fun photosMatchTheReferencePipeline() = runBlocking {
        for (file in golden.keys()) {
            val want = golden.getJSONObject(file).getJSONArray("faces")
            val got = faces(file.removeSuffix(".png"))
            assertEquals(file, want.length(), got.size)
            got.forEachIndexed { i, g ->
                val w = want.getJSONObject(i)
                val emb = w.getJSONArray("embedding").let { e -> FloatArray(e.length()) { e.getDouble(it).toFloat() } }
                val cos = g.faceprint.similarity(Faceprint.of(emb))
                assertTrue("$file cosine $cos", cos > 0.98)
                assertTrue("$file confidence", abs(g.confidence - w.getDouble("score")) < 0.05)
            }
        }
    }

    @Test fun theDetectorAloneFindsWhatFaceFinds() = runBlocking {
        FaceDetector(context, directory).use { detector ->
            for (name in listOf("single_a1", "group", "empty")) {
                val (rgb, w, h) = photo(name)
                assertEquals(name, face.faces(rgb, w, h).map { it.detection }, detector.faces(rgb, w, h, Options.RECOGNITION))
            }
        }
    }

    @Test fun optionsFilterTheFaces() = runBlocking {
        assertEquals(1, faces("group", Options(maxFaces = 1)).size)
        assertEquals(0, faces("group", Options(minimumConfidence = 0.99)).size)
    }

    @Test fun aLibraryOfRealPhotos() = runBlocking {
        val library = face.library()
        for (name in listOf("single_a1", "single_a2", "single_b1", "group", "empty")) library.add(faces(name), name)
        library.regroup()
        assertEquals(listOf(3, 2), library.people().map { it.photoCount })
        val a = library.face("single_a1#0")!!.person!!
        assertEquals(a, library.face("single_a2#0")!!.person)
        assertEquals(a, library.person(faces("single_a2")[0].faceprint)?.id)
        library.name(a, "A")
        assertEquals(mapOf(a to "A"), library.names())
        library.close()
    }

    @Test fun aLibraryLivesInYourOwnDatabase() = runBlocking {
        val rows = HashMap<String, FaceRecord>()
        val library = face.library()
        var n = 0
        for (k in 0 until 6) for (p in 0 until 3) { library.add(noisy(p, 1000 + n), "row-$n", "photo-$p-$k"); n++ }
        library.regroup()
        library.takeChanges().forEach { rows[it.id] = it }
        assertEquals(18, rows.size)
        assertTrue(library.takeChanges().isEmpty())
        val noor = rows["row-0"]!!.person!!
        library.name(noor, "Noor")
        library.reject("row-3", noor)
        library.takeChanges().forEach { rows[it.id] = it }
        assertNull(rows["row-3"]!!.person)
        assertEquals(setOf(noor), rows["row-3"]!!.rejected)
        val names = library.names()
        library.close()

        val back = face.library(rows.values.toList(), names)
        assertTrue(back.takeChanges().isEmpty())
        back.regroup()
        assertEquals("Noor", back.person(noor)?.name)
        assertNotEquals(noor, back.face("row-3")?.person)
        val ana = back.newPerson("row-3", "Ana")
        assertNotNull(ana)
        back.add(noisy(0, 99), "row-new", "new")
        assertEquals(setOf("row-3", "row-new"), back.takeChanges().map { it.id }.toSet())
        assertEquals(noor, back.face("row-new")?.person)
        back.close()
    }
}
