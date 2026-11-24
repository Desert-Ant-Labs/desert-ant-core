package ai.desertant.core

import ai.desertant.DesertAntNative
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RunHistoryTest {
    @After fun reset() = DesertAnt.clearRecentRuns()

    /** A record as Sources/NativeBindings' `runRecord` writes it. */
    private fun record(
        succeeded: Boolean = true,
        millis: Double = 12.5,
        vararg graphs: Triple<String, Pair<Int, Int>, Int>,
    ): ByteArray {
        val writer = FfiWriter().int(1).int(if (succeeded) 1 else 0).double(millis).int(graphs.size)
        for ((name, bits, fallback) in graphs) writer.string(name).int(bits.first).int(bits.second).int(fallback)
        return writer.done()
    }

    @Test fun decodesEveryField() {
        val payload = record(
            true, 12.5,
            Triple("encoder.tflite", 3 to 3, 0),
            Triple("decode_step.tflite", 1 to 1, 0),
        )
        val run = RunHistory.decode("voz", payload, receivedAtMillis = 1_000)!!

        assertEquals("voz", run.modelId)
        assertTrue(run.succeeded)
        assertEquals(12.5, run.durationMillis, 0.0)
        assertEquals(988L, run.startedAtMillis)
        assertEquals(
            listOf(
                GraphRun("encoder.tflite", setOf(Processor.CPU, Processor.GPU), setOf(Processor.CPU, Processor.GPU), null),
                GraphRun("decode_step.tflite", setOf(Processor.CPU), setOf(Processor.CPU), null),
            ),
            run.graphs,
        )
        assertEquals(setOf(Processor.CPU, Processor.GPU), run.processors)
    }

    @Test fun decodesFallbackReasons() {
        val payload = record(false, 1.0, Triple("eye.tflite", 3 to 1, 1), Triple("head.tflite", 3 to 1, 4))
        val run = RunHistory.decode("eye", payload, 0)!!

        assertFalse(run.succeeded)
        assertEquals(listOf(FallbackReason.EMULATOR, FallbackReason.ACCELERATOR_MISSING), run.graphs.map { it.fallbackReason })
        assertEquals(setOf(Processor.CPU), run.processors)
    }

    @Test fun anUnknownFormatVersionIsSkipped() {
        assertNull(RunHistory.decode("eye", FfiWriter().int(2).done(), 0))
    }

    @Test fun recordRunAddsToTheHistory() {
        DesertAntNative.recordRun("emo".toByteArray(), record(true, 3.0, Triple("emo.tflite", 3 to 2, 0)))

        val runs = DesertAnt.recentRuns()
        assertEquals(1, runs.size)
        assertEquals(setOf(Processor.GPU), runs.single().processors)
    }

    /** A truncated record is dropped rather than thrown back across JNI. */
    @Test fun aMalformedRecordIsDropped() {
        DesertAntNative.recordRun("emo".toByteArray(), FfiWriter().int(1).int(1).done())
        assertTrue(DesertAnt.recentRuns().isEmpty())
    }

    @Test fun keepsTheNewestRunsUpToCapacity() {
        repeat(RunHistory.CAPACITY + 44) {
            DesertAntNative.recordRun("emo".toByteArray(), record(true, it.toDouble()))
        }
        val runs = DesertAnt.recentRuns()
        assertEquals(RunHistory.CAPACITY, runs.size)
        assertEquals(44.0, runs.first().durationMillis, 0.0)
        assertEquals((RunHistory.CAPACITY + 43).toDouble(), runs.last().durationMillis, 0.0)
    }

    @Test fun filtersByModelAndClears() {
        DesertAntNative.recordRun("emo".toByteArray(), record())
        DesertAntNative.recordRun("eye".toByteArray(), record())
        DesertAntNative.recordRun("emo".toByteArray(), record())

        assertEquals(2, DesertAnt.recentRuns("emo").size)
        assertEquals(listOf("eye"), DesertAnt.recentRuns("eye").map { it.modelId })

        DesertAnt.clearRecentRuns()
        assertTrue(DesertAnt.recentRuns().isEmpty())
    }
}
