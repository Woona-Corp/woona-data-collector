package com.example.myapplication.storage

import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

data class SessionArchiveMetadata(
    val profileId: String,
    val profileName: String,
    val recordingId: String,
    val source: String,
    val status: String,
    val timezone: String,
    val profileQuestionnaireJson: String?,
    val questionnaireJson: String?,
    val synchronizationJson: String?,
    val sessionLabel: String? = null,
)

class SessionArchiveExporter(
    private val archiveTimestampFormatter: (Long) -> String = { millis ->
        ARCHIVE_TIME_FORMATTER.format(Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault()))
    },
) {
    fun export(
        files: List<File>,
        targetDirectory: File,
        sessionStartMillis: Long?,
        createdAtMillis: Long,
        metadata: SessionArchiveMetadata? = null,
    ): File {
        require(files.isNotEmpty()) { "At least one session file is required" }
        targetDirectory.mkdirs()
        val archiveFile = uniqueArchiveFile(
            directory = targetDirectory,
            baseName = listOfNotNull(
                "woona",
                metadata?.profileName?.toSafeFilePart(),
                metadata?.sessionLabel?.toSafeFilePart(),
                archiveTimestampFormatter(sessionStartMillis ?: createdAtMillis),
            ).joinToString("_"),
        )
        // A collision must never destroy a file the exporter does not own, so the
        // temporary name is made unique instead of deleting an existing file.
        val tempFile = uniqueTempFile(archiveFile)

        return try {
            ZipOutputStream(
                BufferedOutputStream(FileOutputStream(tempFile), BUFFER_SIZE_BYTES),
            ).use { zip ->
                writeManifest(
                    zip = zip,
                    files = files,
                    sessionStartMillis = sessionStartMillis,
                    createdAtMillis = createdAtMillis,
                    metadata = metadata,
                )
                files.forEach { file ->
                    addFile(
                        zip = zip,
                        file = file,
                        entryName = sanitizeZipEntryName(file.name),
                    )
                }
            }

            if (!tempFile.renameTo(archiveFile)) {
                throw IOException("Failed to finalize session archive")
            }
            archiveFile
        } catch (exception: Exception) {
            // Only the temporary file the exporter created may be removed; the
            // uniquely chosen archiveFile is never deleted, even on rename failure.
            tempFile.delete()
            throw exception
        }
    }

    private fun writeManifest(
        zip: ZipOutputStream,
        files: List<File>,
        sessionStartMillis: Long?,
        createdAtMillis: Long,
        metadata: SessionArchiveMetadata?,
    ) {
        // Declare the exact ZIP member name so every manifest name resolves to a
        // real entry regardless of case or characters replaced by sanitization.
        val fileEntries = files.joinToString(separator = ",\n") { file ->
            "    {\"name\":\"${jsonEscape(sanitizeZipEntryName(file.name))}\",\"size\":${file.length()}}"
        }
        val manifest = buildString {
            append("{\n")
            append("  \"createdAtMillis\": $createdAtMillis,\n")
            append("  \"sessionStartMillis\": ")
            append(sessionStartMillis?.toString() ?: "null")
            append(",\n")
            append("  \"profile\": ")
            append(
                metadata?.let {
                    "{\"id\":\"${jsonEscape(it.profileId)}\",\"numberOrName\":\"${jsonEscape(it.profileName)}\"," +
                        "\"questionnaire\":${it.profileQuestionnaireJson ?: "null"}}"
                } ?: "null",
            )
            append(",\n")
            append("  \"recording\": ")
            append(
                metadata?.let {
                    "{\"id\":\"${jsonEscape(it.recordingId)}\",\"source\":\"${jsonEscape(it.source)}\"," +
                        "\"status\":\"${jsonEscape(it.status)}\",\"sessionLabel\":\"${jsonEscape(it.sessionLabel.orEmpty())}\"," +
                        "\"timezone\":\"${jsonEscape(it.timezone)}\"," +
                        "\"questionnaire\":${it.questionnaireJson ?: "null"}}"
                } ?: "null",
            )
            append(",\n")
            append("  \"synchronization\": ")
            append(metadata?.synchronizationJson ?: "null")
            append(",\n")
            append("  \"files\": [\n")
            append(fileEntries)
            append("\n  ]\n")
            append("}\n")
        }
        zip.putNextEntry(ZipEntry(MANIFEST_ENTRY_NAME))
        zip.write(manifest.toByteArray(Charsets.UTF_8))
        zip.closeEntry()
    }

    private fun String.toSafeFilePart(): String? = replace(Regex("[^\\p{L}\\p{N}._-]+"), "_")
        .trim('_')
        .take(48)
        .takeIf(String::isNotBlank)

    private fun addFile(
        zip: ZipOutputStream,
        file: File,
        entryName: String,
    ) {
        zip.putNextEntry(ZipEntry(entryName))
        file.inputStream().use { input ->
            input.copyTo(zip, BUFFER_SIZE_BYTES)
        }
        zip.closeEntry()
    }

    private fun uniqueArchiveFile(
        directory: File,
        baseName: String,
    ): File {
        var candidate = File(directory, "$baseName.zip")
        var suffix = 2
        while (candidate.exists()) {
            candidate = File(directory, "$baseName-$suffix.zip")
            suffix++
        }
        return candidate
    }

    private fun uniqueTempFile(archiveFile: File): File {
        var candidate = File(archiveFile.parentFile, "${archiveFile.name}.tmp")
        var suffix = 2
        while (candidate.exists()) {
            candidate = File(archiveFile.parentFile, "${archiveFile.nameWithoutExtension}-$suffix.zip.tmp")
            suffix++
        }
        return candidate
    }

    // Entry names keep the original file case; the manifest declares the same
    // sanitized name so it always resolves to the actual ZIP member.
    private fun sanitizeZipEntryName(name: String): String {
        return name
            .replace('\\', '_')
            .replace('/', '_')
            .ifBlank { "session_file" }
    }

    private fun jsonEscape(value: String): String {
        return buildString {
            value.forEach { char ->
                when (char) {
                    '\\' -> append("\\\\")
                    '"' -> append("\\\"")
                    '\n' -> append("\\n")
                    '\r' -> append("\\r")
                    '\t' -> append("\\t")
                    else -> append(char)
                }
            }
        }
    }

    private companion object {
        const val BUFFER_SIZE_BYTES = 65_536
        const val MANIFEST_ENTRY_NAME = "manifest.json"
        val ARCHIVE_TIME_FORMATTER: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss")
    }
}
