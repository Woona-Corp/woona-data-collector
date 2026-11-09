package com.example.myapplication.storage

import java.io.File
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.LinkOption

/** Read-only bounded preview of the exact recording's diagnostic artifact.
 * Reject redirected directories/files, including links to a different recording.
 */
fun readRecordingDiagnosticTail(rootDirectory: File, recordingRelativeDirectory: String,
                               artifactRelativePath: String, maxBytes: Int = 32 * 1024): String? = runCatching {
    require(maxBytes in 1..32 * 1024)
    val root = rootDirectory.canonicalFile
    val directory = File(root, recordingRelativeDirectory).absoluteFile.toPath().normalize().toFile()
    require(directory.toPath().startsWith(root.toPath()) && directory != root)
    require(directory.canonicalFile == directory)
    val file = File(root, artifactRelativePath).absoluteFile.toPath().normalize().toFile()
    require(file.parentFile == directory && file.name == "diagnostics.log")
    require(file.canonicalFile == file && !Files.isSymbolicLink(file.toPath()))
    if (!Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS)) return null
    RandomAccessFile(file, "r").use { input ->
        val size = input.length()
        if (size == 0L) return null
        val count = minOf(size, maxBytes.toLong()).toInt()
        input.seek(size - count)
        val bytes = ByteArray(count)
        input.readFully(bytes)
        (if (size > count) "[…]\n" else "") + bytes.toString(Charsets.UTF_8)
    }
}.getOrNull()
