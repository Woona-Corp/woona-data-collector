package com.example.myapplication.storage

import com.example.myapplication.protocol.PolarAccelerationFrame
import com.example.myapplication.protocol.PolarAccelerationSample
import com.example.myapplication.protocol.PolarEcgFrame
import com.example.myapplication.protocol.PolarHeartRateFrame
import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class PolarCsvFileStoreTest {
    @Test
    fun writesAllPolarStreamsIntoSessionDirectory() {
        val directory = File(System.getProperty("java.io.tmpdir"), "polar-store-${System.nanoTime()}")
        val store = PolarCsvFileStore()

        try {
            store.useSessionDirectory(directory)
            assertTrue(store.start())
            store.append(PolarHeartRateFrame(72, listOf(800)), 1_000L)
            store.append(PolarEcgFrame(2UL, listOf(1_000, -1_000)), 1_000L)
            store.append(PolarAccelerationFrame(3UL, listOf(PolarAccelerationSample(1, -2, 3))), 1_000L)
            store.close()

            assertEquals(listOf("1970-01-01T00:00:01Z,72,800"), File(directory, "polar_hr.csv").readLines().drop(1))
            assertEquals(2, File(directory, "polar_ecg.csv").readLines().drop(1).size)
            assertEquals("1970-01-01T00:00:01Z,3,0,1,-2,3", File(directory, "polar_acc.csv").readLines().last())
        } finally {
            directory.listFiles().orEmpty().forEach(File::delete)
            directory.delete()
        }
    }

    @Test
    fun reopeningAppendsWithoutOverwritingAnyPolarStream() {
        val directory = File(System.getProperty("java.io.tmpdir"), "polar-reopen-${System.nanoTime()}")
        val store = PolarCsvFileStore()
        try {
            store.useSessionDirectory(directory)
            assertTrue(store.start())
            store.append(PolarHeartRateFrame(72, listOf(800)), 1_000L)
            store.append(PolarEcgFrame(2UL, listOf(1_000)), 1_000L)
            store.append(PolarAccelerationFrame(3UL, listOf(PolarAccelerationSample(1, 2, 3))), 1_000L)
            store.close()
            val originals = PolarCsvFileStore.FILE_NAMES.associateWith { File(directory, it).readBytes() }
            assertTrue(store.start())
            store.append(PolarHeartRateFrame(80, listOf(750)), 2_000L)
            store.append(PolarEcgFrame(4UL, listOf(2_000)), 2_000L)
            store.append(PolarAccelerationFrame(5UL, listOf(PolarAccelerationSample(4, 5, 6))), 2_000L)
            store.close()
            originals.forEach { (name, original) ->
                val bytes = File(directory, name).readBytes()
                assertArrayEquals(original, bytes.copyOf(original.size))
                assertEquals("Exactly one header in $name", 1, File(directory, name).readLines().count { it.startsWith("host_utc,") })
                assertTrue("New samples must be appended to $name", bytes.size > original.size)
            }
        } finally { store.close(); directory.deleteRecursively() }
    }

    @Test
    fun partialOpenFailureClosesAllWritersAndNeverTruncatesExistingBytes() {
        val directory = File(System.getProperty("java.io.tmpdir"), "polar-partial-${System.nanoTime()}").apply { mkdirs() }
        val hr = File(directory, PolarCsvFileStore.POLAR_HR_FILE).apply { writeText("already-captured\n") }
        val original = hr.readBytes()
        val blocked = File(directory, PolarCsvFileStore.POLAR_ECG_FILE).apply { mkdirs() }
        val store = PolarCsvFileStore()
        try {
            store.useSessionDirectory(directory)
            try { store.start(); fail("Expected second stream open to fail") } catch (_: java.io.IOException) { }
            assertArrayEquals(original, hr.readBytes())
            assertTrue(blocked.delete())
            assertTrue("Retry must open all three streams", store.start())
            store.append(PolarHeartRateFrame(72, listOf(800)), 1_000L)
            store.close()
            assertArrayEquals(original, hr.readBytes().copyOf(original.size))
            assertTrue(File(directory, PolarCsvFileStore.POLAR_ECG_FILE).readText().startsWith("host_utc,"))
            assertTrue(File(directory, PolarCsvFileStore.POLAR_ACC_FILE).readText().startsWith("host_utc,"))
        } finally { store.close(); directory.deleteRecursively() }
    }
    @Test
    fun partialWriteFailureIsStickyAndDoesNotRetryBufferedBytes() {
        val directory = File(System.getProperty("java.io.tmpdir"), "polar-failure-${System.nanoTime()}").apply { mkdirs() }
        val originals = PolarCsvFileStore.FILE_NAMES.associateWith { name ->
            File(directory, name).apply { writeText("existing-$name\n") }.readBytes()
        }
        var writes = 0
        val closed = mutableSetOf<String>()
        val store = PolarCsvFileStore { file ->
            val raw = java.io.FileOutputStream(file, true)
            object : java.io.OutputStream() {
                override fun write(value: Int) = raw.write(value)
                override fun write(bytes: ByteArray, offset: Int, length: Int) {
                    if (file.name == PolarCsvFileStore.POLAR_HR_FILE) {
                        writes++
                        raw.write(bytes, offset, minOf(3, length))
                        throw java.io.IOException("partial write")
                    }
                    raw.write(bytes, offset, length)
                }
                override fun close() { closed += file.name; raw.close() }
            }
        }
        try {
            store.useSessionDirectory(directory)
            store.start()
            store.append(PolarHeartRateFrame(72, listOf(800)), 1_000L)
            val first = try { store.flush(); throw AssertionError("Expected failure") } catch (e: PolarPersistenceException) { e }
            assertTrue(first.message!!.contains("buffered samples may have been lost"))
            assertEquals(1, writes)
            assertEquals(PolarCsvFileStore.FILE_NAMES.toSet(), closed)
            listOf<() -> Unit>({ store.flush() }, { store.close() }, { store.start() }).forEach { action ->
                try { action(); fail("Expected sticky failure") } catch (e: PolarPersistenceException) { assertTrue(e === first) }
            }
            assertEquals(1, writes)
            originals.forEach { (name, original) ->
                assertArrayEquals(original, File(directory, name).readBytes().copyOf(original.size))
            }
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun closeFlushFailureIsReportedAndOtherStreamsClose() {
        val directory = File(System.getProperty("java.io.tmpdir"), "polar-close-failure-${System.nanoTime()}")
        val closed = mutableSetOf<String>()
        var flushes = 0
        val store = PolarCsvFileStore { file ->
            val raw = java.io.FileOutputStream(file, true)
            object : java.io.OutputStream() {
                override fun write(value: Int) = raw.write(value)
                override fun write(bytes: ByteArray, offset: Int, length: Int) = raw.write(bytes, offset, length)
                override fun flush() {
                    if (file.name == PolarCsvFileStore.POLAR_HR_FILE) {
                        flushes++
                        throw java.io.IOException("flush failure")
                    }
                    raw.flush()
                }
                override fun close() { closed += file.name; raw.close() }
            }
        }
        try {
            store.useSessionDirectory(directory)
            store.start()
            // Explicit flush exercises a raw flush failure; close must not retry it.
            try { store.flush(); fail("Expected failure") } catch (_: PolarPersistenceException) { }
            try { store.close(); fail("Expected sticky failure") } catch (_: PolarPersistenceException) { }
            assertEquals(1, flushes)
            assertEquals(PolarCsvFileStore.FILE_NAMES.toSet(), closed)
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun rawCloseFailureIsStickyAndClosesRemainingStreams() {
        val directory = File(System.getProperty("java.io.tmpdir"), "polar-close-error-${System.nanoTime()}")
        val closed = mutableSetOf<String>()
        val store = PolarCsvFileStore { file ->
            val raw = java.io.FileOutputStream(file, true)
            object : java.io.OutputStream() {
                override fun write(value: Int) = raw.write(value)
                override fun write(bytes: ByteArray, offset: Int, length: Int) = raw.write(bytes, offset, length)
                override fun close() {
                    closed += file.name
                    raw.close()
                    if (file.name == PolarCsvFileStore.POLAR_HR_FILE) throw java.io.IOException("close failure")
                }
            }
        }
        try {
            store.useSessionDirectory(directory)
            store.start()
            val first = try { store.close(); throw AssertionError("Expected close failure") } catch (e: PolarPersistenceException) { e }
            assertEquals(PolarCsvFileStore.FILE_NAMES.toSet(), closed)
            try { store.start(); fail("Expected sticky failure") } catch (e: PolarPersistenceException) { assertTrue(e === first) }
        } finally { directory.deleteRecursively() }
    }

}
