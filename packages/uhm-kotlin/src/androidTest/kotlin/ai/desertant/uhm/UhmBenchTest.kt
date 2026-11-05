package ai.desertant.uhm

import android.os.Build
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.PI
import kotlin.math.sin

// Opt-in: UHM_BENCH=1 [UHM_BENCH_N=5] mise run test:android uhm logs one UHM_BENCH JSON line (tag UhmBench).
@RunWith(AndroidJUnit4::class)
class UhmBenchTest {
    private val args = InstrumentationRegistry.getArguments()

    @Test fun realtimeFactor() = runBlocking {
        assumeTrue("set UHM_BENCH", args.getString("UHM_BENCH") != null)
        val n = args.getString("UHM_BENCH_N")?.toIntOrNull() ?: 5
        val seconds = 300
        val samples = FloatArray(seconds * 16_000) { i ->
            val t = i / 16_000.0
            ((0.5 + 0.5 * sin(2 * PI * 4 * t)) * 0.2 * sin(2 * PI * 180 * t)).toFloat()
        }
        val soc = if (Build.VERSION.SDK_INT >= 31) "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}" else Build.HARDWARE
        val out = JSONObject()
            .put("runtime", "android ${Build.MANUFACTURER} ${Build.MODEL} api ${Build.VERSION.SDK_INT} ${Build.SUPPORTED_ABIS.first()}")
            .put("soc", soc)
            .put("audio_seconds", seconds)
        val uhm = Uhm(InstrumentationRegistry.getInstrumentation().targetContext)
        try {
            uhm.download()
            var t = System.nanoTime()
            uhm.detect(samples)
            out.put("first_ms", (System.nanoTime() - t) / 1_000_000)
            val runs = (1..n).map {
                t = System.nanoTime()
                uhm.detect(samples)
                (System.nanoTime() - t) / 1e6
            }.sorted()
            val median = runs[runs.size / 2]
            out.put("warm_ms_median", median.toLong())
            out.put("realtime_factor", "%.1f".format(seconds * 1000 / median).toDouble())
        } finally {
            uhm.close()
        }
        Log.i("UhmBench", "UHM_BENCH $out")
        println("UHM_BENCH $out")
    }
}
