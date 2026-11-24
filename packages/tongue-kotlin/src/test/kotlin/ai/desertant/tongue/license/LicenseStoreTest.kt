package ai.desertant.tongue.license

import ai.desertant.tongue.Tongue
import java.io.File
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardOpenOption
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CyclicBarrier
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LicenseStoreTest {
    private fun newDirectory(): File = Files.createTempDirectory("tongue-license").toFile()

    private fun load(runtime: LicenseRuntime): Boolean = withRuntime(runtime) { Tongue.bundled(null).flushLicenses() }

    @Test
    fun twoStoresOnOneDirectoryThatRaceEndWithOneInstallId() {
        repeat(20) {
            val directory = newDirectory()
            val barrier = CyclicBarrier(2)
            val ids = CopyOnWriteArrayList<String>()
            val threads = List(2) {
                thread {
                    val store = FileStore(directory, {})
                    barrier.await()
                    ids += store.getOrSet(INSTALL_ID_KEY) { UUID.randomUUID().toString() }
                }
            }
            threads.forEach { it.join() }
            assertEquals(1, ids.toSet().size)
            assertEquals(ids.first(), FileStore(directory, {}).get(INSTALL_ID_KEY))
            assertEquals(setOf("tongue.lock", "tongue.properties"), directory.list()!!.toSet())
        }
    }

    @Test
    fun aWriteKeepsWhatAnotherProcessWroteSinceTheLastRead() {
        val directory = newDirectory()
        val first = FileStore(directory, {})
        val second = FileStore(directory, {})
        first.set("a", "1")
        second.set("b", "2")
        first.set("c", "3")
        assertEquals(listOf("1", "2", "3"), listOf("a", "b", "c").map { second.get(it) })
    }

    @Test
    fun aFileThatDoesNotParseIsReplacedByTheNextWrite() {
        val directory = newDirectory()
        File(directory, "tongue.properties").writeText("ai.desertant.usage.deviceId=\\uZZZZ\n")
        val warnings = CopyOnWriteArrayList<String>()
        val store = FileStore(directory, warnings::add)
        assertNull(store.get(INSTALL_ID_KEY))
        assertEquals("made", store.getOrSet(INSTALL_ID_KEY) { "made" })
        assertEquals("made", FileStore(directory, warnings::add).getOrSet(INSTALL_ID_KEY) { "another" })
        assertEquals(emptyList(), warnings.toList())
    }

    @Test
    fun aWriteThatFailedIsTriedAgainWithTheNextOne() {
        val blocker = Files.createTempFile("tongue-license", ".txt").toFile()
        val directory = File(blocker, "state")
        val warnings = CopyOnWriteArrayList<String>()
        val store = FileStore(directory, warnings::add)
        store.set("a", "1")
        assertEquals("1", store.get("a"))
        assertNull(FileStore(directory, {}).get("a"))

        assertTrue(blocker.delete())
        store.set("b", "2")
        assertEquals(listOf("1", "2"), listOf("a", "b").map { FileStore(directory, {}).get(it) })
        assertEquals(1, warnings.size)
    }

    @Test
    fun anInstallIdAnotherProcessStoredWinsOverOneThisProcessCouldNotWrite(): Unit = FakeLicenseServer().use { server ->
        val blocker = Files.createTempFile("tongue-license", ".txt").toFile()
        val directory = File(blocker, "state")
        val a = FileStore(directory, {})
        assertEquals("id-A", a.getOrSet(INSTALL_ID_KEY) { "id-A" })
        assertEquals("id-A", a.get(INSTALL_ID_KEY))

        assertTrue(blocker.delete())
        assertEquals("id-B", FileStore(directory, {}).getOrSet(INSTALL_ID_KEY) { "id-B" })
        a.set("other", "kept")
        assertEquals("id-B", FileStore(directory, {}).get(INSTALL_ID_KEY))
        assertEquals("kept", FileStore(directory, {}).get("other"))
        assertEquals("id-B", a.getOrSet(INSTALL_ID_KEY) { "id-A" })

        assertTrue(load(testRuntime(server.endpoint, a)))
        assertEquals("id-B", server.requests.single().body["installId"])
    }

    @Test
    fun aLockAnotherHolderKeepsDoesNotStopTheStore() {
        val directory = newDirectory()
        FileChannel.open(File(directory, "tongue.lock").toPath(), StandardOpenOption.CREATE, StandardOpenOption.WRITE).use { held ->
            val lock = held.lock()
            val started = System.nanoTime()
            val store = FileStore(directory, {}, lockWaitMs = 300)
            store.set("a", "1")
            val waitedMs = (System.nanoTime() - started) / 1_000_000
            assertTrue(waitedMs >= 250, "waited $waitedMs ms")
            assertEquals("1", FileStore(directory, {}).get("a"))
            lock.release()

            val free = System.nanoTime()
            store.set("b", "2")
            assertTrue((System.nanoTime() - free) / 1_000_000 < 2_000)
            assertEquals("2", FileStore(directory, {}).get("b"))
        }
    }

    @Test
    fun tongueWaitsForTheInstallIdOfTheCoreBeforeItMakesOne(): Unit = FakeLicenseServer().use { server ->
        val store = MemoryStore()
        var slept = 0L
        val sleep: (Long) -> Unit = {
            slept += it
            if (slept == 3_000L) store.set(INSTALL_ID_KEY, "the-id-of-the-core")
        }
        assertTrue(load(testRuntime(server.endpoint, store, platform = "android", coreIsPresent = { true }, sleep = sleep)))
        assertEquals("the-id-of-the-core", server.requests.single().body["installId"])
        assertEquals(3_000L, slept)
    }

    @Test
    fun tongueMakesItsInstallIdWhenTheCoreMadeNoneInTenSeconds(): Unit = FakeLicenseServer().use { server ->
        val store = MemoryStore()
        var slept = 0L
        assertTrue(load(testRuntime(server.endpoint, store, platform = "android", coreIsPresent = { true }, sleep = { slept += it })))
        assertEquals(CORE_INSTALL_ID_WAIT_MS, slept)
        assertEquals(store.get(INSTALL_ID_KEY), server.requests.single().body["installId"])
        assertEquals(36, store.get(INSTALL_ID_KEY)!!.length)
    }

    @Test
    fun tongueDoesNotWaitWithoutTheCoreOrWithAStoredId(): Unit = FakeLicenseServer().use { server ->
        var slept = 0L
        assertTrue(load(testRuntime(server.endpoint, platform = "android", sleep = { slept += it })))
        val stored = MemoryStore().apply { set(INSTALL_ID_KEY, "kept") }
        assertTrue(load(testRuntime(server.endpoint, stored, platform = "android", coreIsPresent = { true }, sleep = { slept += it })))
        assertEquals(0L, slept)
        assertEquals("kept", server.requests.last().body["installId"])
    }
}
