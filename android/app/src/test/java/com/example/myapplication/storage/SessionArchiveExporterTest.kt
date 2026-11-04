package com.example.myapplication.storage

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.io.FileNotFoundException
import java.util.zip.ZipFile

class SessionArchiveExporterTest {
    @Test
    fun exportNameUsesSessionTimeInsteadOfLaterExportTime() {
        val tempDirectory = File(System.getProperty("java.io.tmpdir"), "session-archive-name-${System.nanoTime()}")
            .apply { mkdirs() }
        val sourceFile = File(tempDirectory, "packets.bin").apply { writeBytes(byteArrayOf(1)) }

        try {
            val archive = SessionArchiveExporter { it.toString() }.export(
                files = listOf(sourceFile),
                targetDirectory = tempDirectory,
                sessionStartMillis = 1_000L,
                createdAtMillis = 2_000L,
            )

            org.junit.Assert.assertEquals("woona_1000.zip", archive.name)
        } finally {
            tempDirectory.listFiles().orEmpty().forEach(File::delete)
            tempDirectory.delete()
        }
    }

    @Test
    fun export_includesProfileAndRecordingMetadata() {
        val tempDirectory = File(
            System.getProperty("java.io.tmpdir"),
            "session-archive-metadata-${System.nanoTime()}",
        ).apply { mkdirs() }
        val sourceFile = File(tempDirectory, "packets.bin").apply { writeBytes(byteArrayOf(1)) }
        val videoFile = File(tempDirectory, "video.mp4").apply { writeBytes(byteArrayOf(2, 3)) }
        val syncFile = File(tempDirectory, "sync.json").apply {
            writeText("{\"schemaVersion\":1,\"video\":{\"offsetFromSensorNs\":2250000000}}")
        }
        val archive = SessionArchiveExporter(
            archiveTimestampFormatter = { "metadata" },
        ).export(
            files = listOf(sourceFile, videoFile, syncFile),
            targetDirectory = tempDirectory,
            sessionStartMillis = 1_000L,
            createdAtMillis = 2_000L,
            metadata = SessionArchiveMetadata(
                profileId = "dog-id",
                profileName = "Rex",
                recordingId = "recording-id",
                source = "live",
                status = "completed",
                timezone = "Europe/Moscow",
                profileQuestionnaireJson = "{\"numberOrName\":\"Rex\",\"breed\":null}",
                questionnaireJson = "{\"sessionNumber\":\"recording-id\"}",
                synchronizationJson = "{\"schemaVersion\":1,\"video\":{\"offsetFromSensorNs\":2250000000}}",
                sessionLabel = "Morning walk",
            ),
        )

        try {
            val manifest = ZipFile(archive).use { zip ->
                assertTrue(zip.getEntry("video.mp4") != null)
                assertTrue(zip.getEntry("sync.json") != null)
                zip.getInputStream(zip.getEntry("manifest.json")).bufferedReader().readText()
            }
            org.junit.Assert.assertTrue(manifest.contains("\"numberOrName\":\"Rex\""))
            org.junit.Assert.assertTrue(manifest.contains("\"recording-id\""))
            org.junit.Assert.assertTrue(manifest.contains("\"breed\":null"))
            org.junit.Assert.assertTrue(manifest.contains("\"questionnaire\":{\"sessionNumber\""))
            org.junit.Assert.assertTrue(manifest.contains("\"offsetFromSensorNs\":2250000000"))
            org.junit.Assert.assertTrue(manifest.contains("\"sessionLabel\":\"Morning walk\""))
            org.junit.Assert.assertEquals("woona_Rex_Morning_walk_metadata.zip", archive.name)
        } finally {
            tempDirectory.listFiles().orEmpty().forEach(File::delete)
            tempDirectory.delete()
        }
    }

    @Test
    fun export_removesPartialArchiveWhenFileReadFails() {
        val tempDirectory = File(
            System.getProperty("java.io.tmpdir"),
            "session-archive-exporter-${System.nanoTime()}",
        ).apply { mkdirs() }
        val sourceFile = File(tempDirectory, "source.txt").apply { writeText("ok") }
        val missingFile = File(tempDirectory, "missing.txt")
        val exporter = SessionArchiveExporter(
            archiveTimestampFormatter = { "broken" },
        )

        try {
            try {
                exporter.export(
                    files = listOf(sourceFile, missingFile),
                    targetDirectory = tempDirectory,
                    sessionStartMillis = null,
                    createdAtMillis = 1_000L,
                )
                fail("Expected export to fail when a source file is missing")
            } catch (_: FileNotFoundException) {
            }

            assertFalse(File(tempDirectory, "woona_session_broken.zip").exists())
            assertFalse(File(tempDirectory, "woona_session_broken.zip.tmp").exists())
        } finally {
            tempDirectory.listFiles().orEmpty().forEach(File::delete)
            tempDirectory.delete()
        }
    }

    @Test
    fun exportPreservesFileCaseInManifestAndZip() {
        val tempDirectory = File(
            System.getProperty("java.io.tmpdir"),
            "session-archive-case-${System.nanoTime()}",
        ).apply { mkdirs() }
        val sourceFile = File(tempDirectory, "ECG.CSV").apply { writeText("case") }
        val exporter = SessionArchiveExporter(archiveTimestampFormatter = { "case" })

        try {
            val archive = exporter.export(
                files = listOf(sourceFile),
                targetDirectory = tempDirectory,
                sessionStartMillis = 1_000L,
                createdAtMillis = 2_000L,
            )

            ZipFile(archive).use { zip ->
                assertTrue(zip.getEntry("ECG.CSV") != null)
                val manifest = zip.getInputStream(zip.getEntry("manifest.json")).bufferedReader().readText()
                assertTrue(manifest.contains("\"name\":\"ECG.CSV\""))
            }
        } finally {
            tempDirectory.listFiles().orEmpty().forEach(File::delete)
            tempDirectory.delete()
        }
    }

    @Test
    fun exportDoesNotDeleteExistingTemporaryOutput() {
        val tempDirectory = File(
            System.getProperty("java.io.tmpdir"),
            "session-archive-collision-${System.nanoTime()}",
        ).apply { mkdirs() }
        val sourceFile = File(tempDirectory, "packets.bin").apply { writeBytes(byteArrayOf(1)) }
        val foreignFile = File(tempDirectory, "woona_test.zip.tmp").apply { writeText("keep-me") }
        val exporter = SessionArchiveExporter(archiveTimestampFormatter = { "test" })

        try {
            val archive = exporter.export(
                files = listOf(sourceFile),
                targetDirectory = tempDirectory,
                sessionStartMillis = 1_000L,
                createdAtMillis = 2_000L,
            )

            assertTrue(File(tempDirectory, "woona_test.zip").exists())
            assertTrue("Existing temporary output must not be deleted", foreignFile.exists())
            assertTrue("Existing temporary output must stay untouched", foreignFile.readText() == "keep-me")
            assertFalse(File(tempDirectory, "woona_test-2.zip.tmp").exists())
        } finally {
            tempDirectory.listFiles().orEmpty().forEach(File::delete)
            tempDirectory.delete()
        }
    }
}
