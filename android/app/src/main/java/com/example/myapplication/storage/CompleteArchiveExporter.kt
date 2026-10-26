package com.example.myapplication.storage

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Exports only app-owned data roots. Never pass preferences, credentials or a whole sandbox. */
class CompleteArchiveExporter {
    data class Root(val prefix: String, val directory: File, val include: (String) -> Boolean = { true })
    data class Entry(val path: String, val sourcePath: String, val sizeBytes: Long, val sha256: String)
    data class Progress(val completedBytes: Long, val totalBytes: Long, val completedFiles: Int, val totalFiles: Int)
    private data class Source(val name: String, val sourcePath: String, val file: File, val size: Long, val modified: String, val key: String?)

    fun export(
        roots: List<Root>,
        databaseSnapshot: File,
        destination: File,
        metadataJson: String,
        checkCancelled: () -> Unit = {},
        checkDatabaseUnchanged: () -> Unit = {},
        onProgress: (Progress) -> Unit = {},
    ): File {
        require(!destination.exists()) { "Archive destination already exists" }
        val target = destination.canonicalFile
        require(roots.none { target.toPath().startsWith(it.directory.canonicalFile.toPath()) }) {
            "Archive destination must be outside the data being exported"
        }
        target.parentFile?.let { if (!it.isDirectory && !it.mkdirs()) throw IOException("Cannot create archive directory") }
        val partial = File(target.parentFile, target.name + ".part")
        require(!partial.exists()) { "A partial archive already exists at this destination" }
        val sources = listOf(source("data/Woona/woona.sqlite", databaseSnapshot)) + inventory(roots)
        require(sources.map { it.name }.toSet().size == sources.size) { "Duplicate archive entry" }
        val total = sources.fold(0L) { size, item -> Math.addExact(size, item.size) }
        // Stored video barely compresses. Reserve room for a complete streaming ZIP and its directory.
        val required = Math.addExact(total, Math.addExact(16L * 1024 * 1024, sources.size * 1024L))
        if (target.parentFile!!.usableSpace < required) throw IOException("Not enough free space: archive needs approximately $required bytes; ${target.parentFile!!.usableSpace} bytes available. Original data is unchanged.")
        val entries = ArrayList<Entry>()
        var completed = 0L
        try {
            ZipOutputStream(partial.outputStream().buffered(65_536)).use { zip ->
                zip.setLevel(0) // ZIP64 is automatic in java.util.zip; memory does not grow with file size.
                for (item in sources) {
                    checkCancelled()
                    checkSource(item)
                    val digest = MessageDigest.getInstance("SHA-256")
                    var readBytes = 0L
                    zip.putNextEntry(ZipEntry(item.name))
                    item.file.inputStream().buffered(65_536).use { input ->
                        val buffer = ByteArray(65_536)
                        while (true) {
                            checkCancelled()
                            val count = input.read(buffer)
                            if (count < 0) break
                            zip.write(buffer, 0, count)
                            digest.update(buffer, 0, count)
                            readBytes += count
                            completed += count
                            onProgress(Progress(completed, total, entries.size, sources.size))
                        }
                    }
                    zip.closeEntry()
                    if (readBytes != item.size) throw IOException("Data changed during export: ${item.name}. Retry after recording and transfers finish.")
                    checkSource(item)
                    entries.add(Entry(item.name, item.sourcePath, readBytes, digest.digest().joinToString("") { "%02x".format(it) }))
                    onProgress(Progress(completed, total, entries.size, sources.size))
                }
                if (inventory(roots) != sources.drop(1)) throw IOException("Files changed during export. Original data is safe; retry after recording and transfers finish.")
                sources.forEach(::checkSource)
                checkDatabaseUnchanged()
                checkCancelled()
                zip.putNextEntry(ZipEntry("manifest.json"))
                zip.write(manifest(entries, metadataJson).toByteArray(Charsets.UTF_8))
                zip.closeEntry()
            }
            checkCancelled()
            if (!partial.renameTo(target)) throw IOException("Cannot finalize archive. Original data is unchanged.")
            return target
        } catch (failure: Throwable) {
            partial.delete()
            throw failure
        }
    }

    private fun inventory(roots: List<Root>): List<Source> = roots.flatMap { root ->
        safeName(root.prefix)
        if (!root.directory.exists()) emptyList() else {
            require(!Files.isSymbolicLink(root.directory.toPath())) { "Symbolic data root is not exportable" }
            val base = root.directory.canonicalFile.toPath()
            val values = ArrayList<Source>()
            fun visit(directory: File) {
                val children = directory.listFiles() ?: throw IOException("Cannot read data directory: ${directory.name}")
                for (child in children.sortedBy { it.name }) {
                    val relative = base.relativize(child.toPath().toAbsolutePath().normalize()).toString().replace(File.separatorChar, '/')
                    if (!root.include(relative)) continue
                    require(!Files.isSymbolicLink(child.toPath())) { "Symbolic link is not exportable: $relative" }
                    require(child.canonicalFile.toPath().startsWith(base)) { "Data path escapes its root" }
                    if (child.isDirectory) visit(child)
                    else values.add(source("${root.prefix}/${portablePath(relative)}", child, "${root.prefix}/$relative"))
                }
            }
            visit(root.directory.canonicalFile)
            values
        }
    }.sortedBy { it.name }

    private fun source(name: String, file: File, sourcePath: String = name): Source {
        safeName(name)
        val attributes = Files.readAttributes(file.toPath(), BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
        require(attributes.isRegularFile && !attributes.isSymbolicLink) { "Not a regular data file: $name" }
        return Source(name, sourcePath, file, attributes.size(), attributes.lastModifiedTime().toString(), attributes.fileKey()?.toString())
    }

    private fun checkSource(value: Source) {
        if (source(value.name, value.file, value.sourcePath) != value) throw IOException("Data changed during export: ${value.name}. Original data is unchanged; retry when transfers finish.")
    }

    private fun safeName(name: String) {
        require(name.isNotEmpty() && !name.startsWith('/') && !name.contains('\\') && !name.contains('\u0000') &&
            name.split('/').none { it.isEmpty() || it == "." || it == ".." } && !name.contains(':')) { "Unsafe archive path" }
    }

    private fun manifest(entries: List<Entry>, metadata: String): String = """
        {"format":"woona-complete-data-archive","schemaVersion":1,"platform":"android","createdAtUtc":${json(java.time.Instant.now().toString())},
        "scope":"All app-owned local data still available at export time, across every account and animal. This is not a server backup.",
        "limitations":["Physically deleted files and data from another installation or device cannot be recovered by this export.","Server-only artifacts are listed as unavailable locally; export does not download or delete them.","Authentication tokens, Keystore, preferences containing credentials, previous export archives and transient operating-system caches are excluded."],
        "database":$metadata,"fileCount":${entries.size},"totalBytes":${entries.sumOf { it.sizeBytes }},
        "files":[${entries.joinToString(",") { "{\"path\":${json(it.path)},\"sourcePath\":${json(it.sourcePath)},\"sizeBytes\":${it.sizeBytes},\"sha256\":${json(it.sha256)}}" }}]}
    """.trimIndent()

    companion object {
        fun json(value: String): String = buildString {
            append('"')
            value.forEach { c -> when (c) {
                '"' -> append("\\\""); '\\' -> append("\\\\"); '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t")
                else -> if (c.code < 32) append("\\u%04x".format(c.code)) else append(c)
            } }
            append('"')
        }
        fun portablePath(relative: String): String = buildString {
            relative.forEach { c ->
                if (c.code < 32 || c in "%<>:\"\\|?*") append("%%%02X".format(c.code)) else append(c)
            }
        }
        fun isDatabaseFile(relative: String): Boolean = relative in setOf("woona.sqlite", "woona.sqlite-wal", "woona.sqlite-shm", "woona.sqlite-journal")
        fun isLegacyData(relative: String): Boolean = !relative.contains('/') &&
            (relative.startsWith("ble_") || relative.startsWith("polar_") || relative.startsWith("debug-replay-")) &&
            relative.substringAfterLast('.', "") in setOf("bin", "binlog", "log", "csv", "json", "mp4", "part", "tmp")
    }
}
