package com.example.myapplication.storage

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class RecordingDiagnosticPreviewTest {
    @Test fun missingEmptyAndForeignPathsDoNotExposeFiles() {
        val root = Files.createTempDirectory("diagnostic-preview").toFile()
        try {
            val dir = File(root, "recordings/one").apply { mkdirs() }
            val path = "recordings/one/diagnostics.log"
            assertNull(readRecordingDiagnosticTail(root, "recordings/one", path))
            File(dir, "diagnostics.log").writeText("")
            assertNull(readRecordingDiagnosticTail(root, "recordings/one", path))
            File(root, "private.txt").writeText("foreign data")
            assertNull(readRecordingDiagnosticTail(root, "recordings/one", "private.txt"))
            assertNull(readRecordingDiagnosticTail(root, "../escape", "../escape/diagnostics.log"))
        } finally { root.deleteRecursively() }
    }

    @Test fun readIsBoundedAndOriginalRemainsUnchanged() {
        val root = Files.createTempDirectory("diagnostic-tail").toFile()
        try {
            val file = File(root, "recordings/one/diagnostics.log").apply { parentFile.mkdirs(); writeText("a".repeat(40000) + "TAIL") }
            val before = file.readBytes()
            val shown = requireNotNull(readRecordingDiagnosticTail(root, "recordings/one", "recordings/one/diagnostics.log"))
            assertTrue(shown.startsWith("[…]\n"))
            assertTrue(shown.endsWith("TAIL"))
            assertTrue(shown.length <= 32768 + 4)
            assertArrayEquals(before, file.readBytes())
        } finally { root.deleteRecursively() }
    }

    @Test fun linkedFilesAndLinkedDirectoriesAreRejected() {
        val root = Files.createTempDirectory("diagnostic-links").toFile()
        try {
            val other = File(root, "recordings/two/diagnostics.log").apply { parentFile.mkdirs(); writeText("other recording") }
            val dir = File(root, "recordings/one").apply { mkdirs() }
            Files.createSymbolicLink(File(dir, "diagnostics.log").toPath(), other.toPath())
            assertNull(readRecordingDiagnosticTail(root, "recordings/one", "recordings/one/diagnostics.log"))
            Files.createSymbolicLink(File(root, "recordings/alias").toPath(), other.parentFile.toPath())
            assertNull(readRecordingDiagnosticTail(root, "recordings/alias", "recordings/alias/diagnostics.log"))
        } finally { root.deleteRecursively() }
    }
}
