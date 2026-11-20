package ai.desertant.face

import android.os.Build
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Speed through the public API, the cases of Tests/FaceTests/BenchTests.swift: median milliseconds per photo for
 * FaceDetector and Face, on the two-face test photo and on it scaled to 12 MP, and seconds to add 20,000 faces to a
 * library one photo at a time and group them. Opt-in: instrumentation argument FACE_BENCH (forwarded by
 * `mise run test:android` from the environment), FACE_BENCH_N runs per case. Logs one `FACE_BENCH` JSON line.
 */
@RunWith(AndroidJUnit4::class)
class FaceBenchTest {
    private val args = InstrumentationRegistry.getArguments()
    private val assets = InstrumentationRegistry.getInstrumentation().context.assets

    @Test fun speed() = runBlocking {
        assumeTrue("set FACE_BENCH", args.getString("FACE_BENCH") != null)
        val n = args.getString("FACE_BENCH_N")?.toIntOrNull() ?: 30
        val b = assets.open("group.rgb").readBytes()
        val head = ByteBuffer.wrap(b, 0, 8).order(ByteOrder.LITTLE_ENDIAN)
        val w = head.int
        val h = head.int
        val small = b.copyOfRange(8, 8 + w * h * 3)
        val bigW = 5070
        val bigH = bigW * h / w
        val big = ByteArray(bigW * bigH * 3)
        for (y in 0 until bigH) for (x in 0 until bigW) {
            val s = ((y * h / bigH) * w + x * w / bigW) * 3
            val d = (y * bigW + x) * 3
            big[d] = small[s]; big[d + 1] = small[s + 1]; big[d + 2] = small[s + 2]
        }
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val face = Face(context)
        val detector = FaceDetector(context)
        val out = JSONObject().put("runtime", "android ${Build.MANUFACTURER} ${Build.MODEL} api ${Build.VERSION.SDK_INT} ${Build.SOC_MODEL}")
        try {
            face.download()
            detector.download()
            var t = System.nanoTime()
            face.faces(small, w, h)
            out.put("face_first_ms", (System.nanoTime() - t) / 1_000_000)
            for ((name, bytes, width) in listOf(Triple("photo", small, w), Triple("12mp", big, bigW))) {
                val height = bytes.size / 3 / width
                out.put("detector_${name}_ms", median(n) { detector.faces(bytes, width, height) })
                out.put("face_${name}_ms", median(n) { face.faces(bytes, width, height) })
            }
            val library = face.library()
            val r = java.util.Random(7)
            t = System.nanoTime()
            for (k in 0 until 5000) {
                library.add((0 until 4).map { i ->
                    val v = FloatArray(128) { (r.nextGaussian() * 0.6 / Math.sqrt(128.0)).toFloat() }
                    v[((k * 4 + i) % 500) % 128] += 1f
                    DetectedFace(Box(0.1, 0.1, 0.3, 0.3), emptyList(), 0.9, Faceprint.of(v))
                }, "img$k")
            }
            library.regroup()
            out.put("library_20000_s", "%.2f".format((System.nanoTime() - t) / 1e9).toDouble())
            out.put("library_people", library.people().size)
            library.close()
        } finally {
            face.close()
            detector.close()
        }
        Log.i("FaceBench", "FACE_BENCH $out")
        println("FACE_BENCH $out")
    }

    private suspend fun median(n: Int, body: suspend () -> Unit): Double {
        repeat(2) { body() }
        val times = (0 until n).map {
            val t = System.nanoTime()
            body()
            (System.nanoTime() - t) / 1e6
        }.sorted()
        return "%.1f".format(times[n / 2]).toDouble()
    }
}
