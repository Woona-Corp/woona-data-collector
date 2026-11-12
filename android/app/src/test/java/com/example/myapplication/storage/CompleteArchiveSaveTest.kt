package com.example.myapplication.storage

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.nio.file.Files
import java.util.concurrent.CancellationException

class CompleteArchiveSaveTest {
    private fun fixture(run: (File) -> Unit) {
        val directory = Files.createTempDirectory("complete-save-test").toFile()
        val archive = File(directory, "prepared.zip").apply { writeBytes(ByteArray(200_000) { (it % 251).toByte() }) }
        try { run(archive) } finally { directory.deleteRecursively() }
    }

    @Test fun copiesAllBytesToSelectedDestinationAndReportsProgress() = fixture { archive ->
        val output = ByteArrayOutputStream()
        var progress = 0L to 0L
        copyCompleteArchive(archive, { output }, onProgress = { copied, total -> progress = copied to total })
        assertArrayEquals(archive.readBytes(), output.toByteArray())
        assertEquals(archive.length() to archive.length(), progress)
        assertTrue(archive.isFile)
    }

    @Test fun missingOrCancelledArchiveDoesNotOpenDestination() = fixture { archive ->
        var opened = false
        assertThrows(CancellationException::class.java) {
            copyCompleteArchive(archive, { opened = true; ByteArrayOutputStream() }, checkCancelled = { throw CancellationException() })
        }
        assertFalse(opened)
        assertThrows(IOException::class.java) {
            copyCompleteArchive(File(archive.parentFile, "missing.zip"), { opened = true; ByteArrayOutputStream() })
        }
        assertFalse(opened)
        assertTrue(archive.isFile)
    }

    @Test fun writeFailureOrCancellationPreservesPreparedArchive() = fixture { archive ->
        val original = archive.readBytes()
        val broken = object : OutputStream() {
            override fun write(value: Int) { throw IOException("destination full") }
            override fun write(bytes: ByteArray, offset: Int, length: Int) { throw IOException("destination full") }
        }
        assertThrows(IOException::class.java) { copyCompleteArchive(archive, { broken }) }
        var checks = 0
        assertThrows(CancellationException::class.java) {
            copyCompleteArchive(archive, { ByteArrayOutputStream() }, checkCancelled = { if (++checks > 2) throw CancellationException() })
        }
        assertArrayEquals(original, archive.readBytes())
    }

    @Test fun nullDestinationAndCloseFailureAreReported() = fixture { archive ->
        assertThrows(IOException::class.java) { copyCompleteArchive(archive, { null }) }
        val broken = object : ByteArrayOutputStream() {
            override fun close() { throw IOException("close failed") }
        }
        assertThrows(IOException::class.java) { copyCompleteArchive(archive, { broken }) }
        assertTrue(archive.isFile)
    }

    @Test fun discardDeletesOnlyPreparedArchiveAndEmptyExportDirectory() {
        val directory = Files.createTempDirectory("complete-discard-test").toFile()
        try {
            val exportRoot = File(directory, "cache/woona_complete_exports")
            val exportDirectory = File(exportRoot, java.util.UUID.randomUUID().toString()).apply { mkdirs() }
            val archive = File(exportDirectory, "prepared.zip").apply { writeText("prepared") }
            val source = File(directory, "files/Woona/recordings/source.bin").apply { parentFile!!.mkdirs(); writeText("source") }

            discardCompleteArchive(archive)

            assertFalse(archive.exists())
            assertFalse(exportDirectory.exists())
            assertTrue(exportRoot.isDirectory)
            assertEquals("source", source.readText())
        } finally { directory.deleteRecursively() }
    }

    @Test fun discardNeverRecursivelyDeletesExportDirectoryContents() {
        val directory = Files.createTempDirectory("complete-discard-test").toFile()
        try {
            val exportDirectory = File(directory, "woona_complete_exports/${java.util.UUID.randomUUID()}").apply { mkdirs() }
            val archive = File(exportDirectory, "prepared.zip").apply { writeText("prepared") }
            val sibling = File(exportDirectory, "keep.bin").apply { writeText("keep") }

            discardCompleteArchive(archive)

            assertFalse(archive.exists())
            assertEquals("keep", sibling.readText())
            assertTrue(exportDirectory.isDirectory)
        } finally { directory.deleteRecursively() }
    }
}
