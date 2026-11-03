package com.example.myapplication.storage

import java.io.File
import java.io.IOException
import java.io.OutputStream

/** Streams a prepared archive to the selected document; never deletes either file. */
internal fun copyCompleteArchive(
    archive: File,
    openDestination: () -> OutputStream?,
    checkCancelled: () -> Unit = {},
    onProgress: (Long, Long) -> Unit = { _, _ -> },
) {
    if (!archive.isFile) throw IOException("The prepared archive is no longer available. Create it again.")
    val size = archive.length()
    val modified = archive.lastModified()
    checkCancelled()
    val destination = openDestination() ?: throw IOException("Cannot open the selected destination for writing.")
    destination.use { output ->
        archive.inputStream().buffered(65_536).use { input ->
            val buffer = ByteArray(65_536)
            var copied = 0L
            while (true) {
                checkCancelled()
                val count = input.read(buffer)
                if (count < 0) break
                output.write(buffer, 0, count)
                copied += count
                onProgress(copied, size)
            }
            if (copied != size || archive.length() != size || archive.lastModified() != modified) {
                throw IOException("The prepared archive changed while saving. Create it again.")
            }
            checkCancelled()
        }
    }
}
