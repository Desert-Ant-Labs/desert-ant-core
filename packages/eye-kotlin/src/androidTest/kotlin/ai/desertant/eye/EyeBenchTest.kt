package ai.desertant.eye

import android.os.Build
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.atomic.AtomicInteger

/**
 * Images per second through the public API, the cases of Tests/EyeTests/ThroughputTests.swift.
 * Opt-in: instrumentation argument EYE_BENCH (forwarded by `mise run test:android` from the
 * environment), EYE_BENCH_N runs per case. Logs one `EYE_BENCH` JSON line (tag EyeBench).
 */
@RunWith(AndroidJUnit4::class)
class EyeBenchTest {
    private val args = InstrumentationRegistry.getArguments()
    private val assets = InstrumentationRegistry.getInstrumentation().context.assets

    @Test fun throughput() = runBlocking {
        assumeTrue("set EYE_BENCH", args.getString("EYE_BENCH") != null)
        val n = args.getString("EYE_BENCH_N")?.toIntOrNull() ?: 30
        val golden = JSONObject(assets.open("eye_golden.json").bufferedReader().readText()).getJSONObject("fixture")
        val w = golden.getInt("width"); val h = golden.getInt("height")
        val gray = assets.open("eye_fixture.gray").readBytes()
        val small = ByteArray(gray.size * 3).also { for (i in gray.indices) { it[i * 3] = gray[i]; it[i * 3 + 1] = gray[i]; it[i * 3 + 2] = gray[i] } }
        val bigW = 4032; val bigH = bigW * h / w
        val big = ByteArray(bigW * bigH * 3)
        for (y in 0 until bigH) for (x in 0 until bigW) {
            val s = ((y * h / bigH) * w + x * w / bigW) * 3; val d = (y * bigW + x) * 3
            big[d] = small[s]; big[d + 1] = small[s + 1]; big[d + 2] = small[s + 2]
        }
        val eye = Eye(ApplicationProvider.getApplicationContext())
        val out = JSONObject().put("runtime", "android ${Build.MODEL} api ${Build.VERSION.SDK_INT} ${Build.SUPPORTED_ABIS.first()}")
        try {
            eye.download()
            var t = System.nanoTime()
            eye.analyze(small, w, h)
            out.put("first_ms", (System.nanoTime() - t) / 1_000_000)
            for ((name, bytes, size) in listOf(Triple("fixture", small, w to h), Triple("12mp", big, bigW to bigH))) {
                for ((partName, options) in listOf("all" to Options(), "photo" to Options(parts = setOf(Part.PHOTO)))) {
                    repeat(2) { eye.analyze(bytes, size.first, size.second, options) }
                    t = System.nanoTime()
                    repeat(n) { eye.analyze(bytes, size.first, size.second, options) }
                    val serial = n * 1e9 / (System.nanoTime() - t)
                    val next = AtomicInteger(0)
                    t = System.nanoTime()
                    withContext(Dispatchers.Default) {
                        (0 until 4).map { async { while (next.getAndIncrement() < n) eye.analyze(bytes, size.first, size.second, options) } }.awaitAll()
                    }
                    val parallel = n * 1e9 / (System.nanoTime() - t)
                    out.put("${name}_$partName", JSONObject().put("serial", "%.2f".format(serial).toDouble()).put("parallel4", "%.2f".format(parallel).toDouble()))
                }
            }
        } finally {
            eye.close()
        }
        Log.i("EyeBench", "EYE_BENCH $out")
        println("EYE_BENCH $out")
    }
}
