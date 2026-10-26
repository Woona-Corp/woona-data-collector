package com.example.myapplication.storage

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CancellationException
import java.util.zip.ZipFile

class CompleteArchiveExporterTest {
    private fun fixture(run: (File, File, File) -> Unit) {
        val directory = Files.createTempDirectory("complete-export-test").toFile()
        val root = File(directory, "Woona").apply { mkdirs() }
        val snapshot = File(directory, "snapshot.sqlite").apply { writeText("consistent SQLite snapshot") }
        try { run(directory, root, snapshot) } finally { directory.deleteRecursively() }
    }
    @Test fun includesEveryNestedOrphanPartialAndUnicodeFileAndExactHashes() = fixture { base, root, snapshot ->
        File(root, "recordings/животное/old.bin.part").apply { parentFile!!.mkdirs(); writeBytes(byteArrayOf(0, 1, -1)) }
        File(root, "ble_dump_old.bin").writeText("legacy")
        File(root, "orphan/recovery.json").apply { parentFile!!.mkdirs(); writeText("{}") }
        File(root, "empty.csv").writeText("")
        val archive = CompleteArchiveExporter().export(listOf(CompleteArchiveExporter.Root("data/Woona", root)), snapshot, File(base, "out.zip"), "{\"counts\":{\"dogs\":7}}")
        ZipFile(archive).use { zip ->
            assertEquals(6, zip.size())
            assertEquals(listOf<Byte>(0, 1, -1), zip.getInputStream(zip.getEntry("data/Woona/recordings/животное/old.bin.part")).readBytes().toList())
            assertEquals("consistent SQLite snapshot", zip.getInputStream(zip.getEntry("data/Woona/woona.sqlite")).reader().readText())
            val manifest = zip.getInputStream(zip.getEntry("manifest.json")).reader().readText()
            val hash = MessageDigest.getInstance("SHA-256").digest(byteArrayOf(0, 1, -1)).joinToString("") { "%02x".format(it) }
            assertTrue(manifest.contains(hash))
            assertTrue(manifest.contains("\"dogs\":7"))
            assertTrue(manifest.contains("\"fileCount\":5"))
            assertTrue(manifest.contains("Physically deleted"))
        }
    }
    @Test fun emptyInstallationStillExportsDatabaseAndManifest() = fixture { base, root, snapshot ->
        val output = CompleteArchiveExporter().export(listOf(CompleteArchiveExporter.Root("data/Woona", root)), snapshot, File(base, "out.zip"), "{}")
        ZipFile(output).use { assertEquals(2, it.size()) }
    }
    @Test fun cancellationRemovesPartialAndPreservesOriginal() = fixture { base, root, snapshot ->
        val source = File(root, "video.mp4").apply { writeBytes(ByteArray(2 * 1024 * 1024) { 42 }) }
        var reads = 0
        assertThrows(CancellationException::class.java) {
            CompleteArchiveExporter().export(listOf(CompleteArchiveExporter.Root("data/Woona", root)), snapshot, File(base, "out.zip"), "{}", checkCancelled = { if (++reads > 5) throw CancellationException() })
        }
        assertFalse(File(base, "out.zip").exists())
        assertFalse(File(base, "out.zip.part").exists())
        assertEquals(2 * 1024 * 1024L, source.length())
    }
    @Test fun concurrentAppendFailsWithoutPublishingArchive() = fixture { base, root, snapshot ->
        val file = File(root, "video.mp4").apply { writeBytes(ByteArray(1024 * 1024)) }
        var changed = false
        assertThrows(IOException::class.java) {
            CompleteArchiveExporter().export(listOf(CompleteArchiveExporter.Root("data/Woona", root)), snapshot, File(base, "out.zip"), "{}", onProgress = {
                if (!changed) { changed = true; file.appendText("changed") }
            })
        }
        assertFalse(File(base, "out.zip.part").exists())
        assertTrue(file.exists())
    }
    @Test fun newFileDuringExportIsDetected() = fixture { base, root, snapshot ->
        assertThrows(IOException::class.java) {
            CompleteArchiveExporter().export(listOf(CompleteArchiveExporter.Root("data/Woona", root)), snapshot, File(base, "out.zip"), "{}", onProgress = { File(root, "new.bin").writeText("new") })
        }
        assertFalse(File(base, "out.zip").exists())
        assertFalse(File(base, "out.zip.part").exists())
    }
    @Test fun databaseMutationDiscardsArchive() = fixture { base, root, snapshot ->
        assertThrows(IOException::class.java) {
            CompleteArchiveExporter().export(listOf(CompleteArchiveExporter.Root("data/Woona", root)), snapshot, File(base, "out.zip"), "{}", checkDatabaseUnchanged = { throw IOException("database changed") })
        }
        assertFalse(File(base, "out.zip.part").exists())
    }
    @Test fun traversalSymlinkAndDuplicatePathsAreRejected() = fixture { base, root, snapshot ->
        File(root, "one.bin").writeText("one")
        assertThrows(IllegalArgumentException::class.java) {
            CompleteArchiveExporter().export(listOf(CompleteArchiveExporter.Root("../outside", root)), snapshot, File(base, "out.zip"), "{}")
        }
        assertThrows(IllegalArgumentException::class.java) {
            CompleteArchiveExporter().export(listOf(CompleteArchiveExporter.Root("data/Woona", root), CompleteArchiveExporter.Root("data/Woona", root)), snapshot, File(base, "out.zip"), "{}")
        }
        Files.createSymbolicLink(File(root, "escape.bin").toPath(), snapshot.toPath())
        assertThrows(IllegalArgumentException::class.java) {
            CompleteArchiveExporter().export(listOf(CompleteArchiveExporter.Root("data/Woona", root)), snapshot, File(base, "out.zip"), "{}")
        }
    }
    @Test fun archiveCannotBeWrittenIntoSourceAndExistingOutputIsPreserved() = fixture { base, root, snapshot ->
        assertThrows(IllegalArgumentException::class.java) {
            CompleteArchiveExporter().export(listOf(CompleteArchiveExporter.Root("data/Woona", root)), snapshot, File(root, "out.zip"), "{}")
        }
        val output = File(base, "out.zip").apply { writeText("existing") }
        assertThrows(IllegalArgumentException::class.java) { CompleteArchiveExporter().export(emptyList(), snapshot, output, "{}") }
        assertEquals("existing", output.readText())
    }
    @Test fun largeFileUsesBoundedReadsAndValidZip() = fixture { base, root, snapshot ->
        val video = File(root, "video.mp4")
        video.outputStream().use { out -> repeat(128) { out.write(ByteArray(65_536) { n -> (n % 251).toByte() }) } }
        var reports = 0
        val output = CompleteArchiveExporter().export(listOf(CompleteArchiveExporter.Root("data/Woona", root)), snapshot, File(base, "out.zip"), "{}", onProgress = { reports++ })
        assertTrue(reports > 128)
        ZipFile(output).use { zip ->
            assertEquals(video.length(), zip.getEntry("data/Woona/video.mp4").size)
            assertEquals(video.length(), zip.getInputStream(zip.getEntry("data/Woona/video.mp4")).use { it.copyTo(java.io.OutputStream.nullOutputStream()) })
        }
    }
    @Test fun legalImportedFilenamesArePortableAndOriginalNamesRemainInManifest() = fixture { base, root, snapshot ->
        File(root, "reference-ECG: 100%.csv").writeText("reference")
        val output = CompleteArchiveExporter().export(listOf(CompleteArchiveExporter.Root("data/Woona", root)), snapshot, File(base, "out.zip"), "{}")
        ZipFile(output).use { zip ->
            assertEquals("reference", zip.getInputStream(zip.getEntry("data/Woona/reference-ECG%3A 100%25.csv")).reader().readText())
            assertTrue(zip.getInputStream(zip.getEntry("manifest.json")).reader().readText().contains("reference-ECG: 100%.csv"))
        }
    }
    @Test fun legacyAllowlistExcludesCredentialsAndOldArchives() {
        assertTrue(CompleteArchiveExporter.isLegacyData("ble_dump_42.bin"))
        assertTrue(CompleteArchiveExporter.isLegacyData("debug-replay-42.bin"))
        assertFalse(CompleteArchiveExporter.isLegacyData("connection-test.token"))
        assertFalse(CompleteArchiveExporter.isLegacyData("server_settings.xml"))
        assertFalse(CompleteArchiveExporter.isLegacyData("ble_archive.zip"))
        assertFalse(CompleteArchiveExporter.isLegacyData("sub/ble_dump.bin"))
    }
}
