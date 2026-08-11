package ai.desertant.core

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class LoadedModelTest {
    /** The audio payload: an int count then big-endian floats, matching Swift's
     *  `FFIWriter.f32Array` and the JavaScript `FfiWriter.f32Array`. */
    @Test fun floatArraysRoundTripThroughTheFfiCodec() {
        val values = floatArrayOf(0f, 1f, -1f, 0.5f, -0.25f)
        val bytes = FfiWriter().floats(values).double(48_000.0).done()
        assertEquals(4 + values.size * 4 + 8, bytes.size)

        val r = FfiReader(bytes)
        assertArrayEquals(values, r.floats(), 0f)
        assertEquals(48_000.0, r.double(), 0.0)
        assertFalse(r.hasRemaining())
    }

    /** A field appended after a release has to read as absent, not as garbage,
     *  for a host built against the older schema. */
    @Test fun hasRemainingGuardsAnAppendedField() {
        val r = FfiReader(FfiWriter().floats(floatArrayOf(1f)).double(1.0).done())
        r.floats()
        assertTrue(r.hasRemaining())
        r.double()
        assertFalse(r.hasRemaining())
    }

    @Test fun createsTheRightCatalogHandleWithoutLoadingTheRuntime() {
        val native = FakeNative()
        model(native, directory = "/models/emo")

        assertTrue(native.loaded)
        assertEquals("emo", native.modelId.decodeToString())
        assertEquals("/cache", native.cacheRoot.decodeToString())
        assertEquals("/models/emo", native.directory?.decodeToString())
        assertEquals(1, native.creates)
        assertEquals(0, native.downloads)
        assertEquals(0, native.runs)
    }

    @Test fun availabilityDownloadAndRunUseOneHandle() = runBlocking {
        val native = FakeNative().apply {
            available = 1
            result = FfiWriter().int(42).done()
        }
        val model = model(native)

        assertTrue(model.isDownloaded())
        model.download()
        val options = byteArrayOf(1, 2, 3)
        // The input is the model's own payload, like the options and the result,
        // so nothing here knows the model takes text.
        val input = FfiWriter().string("hello").done()
        val result = model.run(input, options) { it.int() }

        assertEquals(42, result)
        assertEquals(listOf(73L, 73L, 73L), native.usedHandles)
        assertArrayEquals(input, native.input)
        assertArrayEquals(options, native.options)
    }

    @Test fun nativeFailuresBecomeTheModelsException() {
        val unavailable = FakeNative().apply { createResult = 0 }
        val create = assertThrows(TestModelException::class.java) { model(unavailable) }
        assertEquals("failed to create Emo", create.message)

        val downloadNative = FakeNative().apply { downloadResult = 1 }
        val download = assertThrows(TestModelException::class.java) {
            runBlocking { model(downloadNative).download() }
        }
        assertEquals("model download failed", download.message)

        val runNative = FakeNative().apply { result = null }
        val run = assertThrows(TestModelException::class.java) {
            runBlocking {
                model(runNative)
                    .run(FfiWriter().string("hello").done(), failureMessage = "suggestion failed") { it.int() }
            }
        }
        assertEquals("suggestion failed", run.message)
    }

    @Test fun closeReleasesExactlyOnceAndGuardsEveryOperation() {
        val native = FakeNative()
        val model = model(native)
        model.close()
        model.close()

        assertEquals(1, native.destroys)
        assertEquals(73L, native.destroyedHandle)
        val availability = assertThrows(TestModelException::class.java) { model.isDownloaded() }
        assertEquals("this Emo is closed", availability.message)
        assertThrows(TestModelException::class.java) { runBlocking { model.download() } }
        assertThrows(TestModelException::class.java) {
            runBlocking { model.run(FfiWriter().string("hello").done()) { it.int() } }
        }
        assertFalse(native.usedHandles.isNotEmpty())
    }

    private fun model(native: FakeNative, directory: String? = null) = LoadedModel(
        modelId = "emo",
        name = "Emo",
        cacheRoot = "/cache",
        directory = directory,
        fail = ::TestModelException,
        native = native,
    )
}

private class TestModelException(message: String) : Exception(message)

private class FakeNative : NativeModelApi {
    var loaded = false
    var creates = 0
    var createResult = 73L
    var modelId = byteArrayOf()
    var cacheRoot = byteArrayOf()
    var directory: ByteArray? = null
    var available = 0
    var downloads = 0
    var downloadResult = 0
    var runs = 0
    var input = byteArrayOf()
    var options: ByteArray? = null
    var result: ByteArray? = byteArrayOf()
    val usedHandles = mutableListOf<Long>()
    var destroys = 0
    var destroyedHandle = 0L

    override fun ensureLoaded() { loaded = true }

    override fun create(modelId: ByteArray, cacheRoot: ByteArray?, directory: ByteArray?): Long {
        creates += 1
        this.modelId = modelId
        this.cacheRoot = checkNotNull(cacheRoot)
        this.directory = directory
        return createResult
    }

    override fun destroy(handle: Long) {
        destroys += 1
        destroyedHandle = handle
    }

    override fun isDownloaded(handle: Long): Int {
        usedHandles += handle
        return available
    }

    override fun download(handle: Long): Int {
        usedHandles += handle
        downloads += 1
        return downloadResult
    }

    override fun run(handle: Long, input: ByteArray, options: ByteArray?): ByteArray? {
        usedHandles += handle
        runs += 1
        this.input = input
        this.options = options
        return result
    }
}
