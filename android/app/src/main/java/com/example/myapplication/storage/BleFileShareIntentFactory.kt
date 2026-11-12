package com.example.myapplication.storage

import android.content.Context
import android.content.ClipData
import android.content.Intent
import androidx.core.content.FileProvider
import com.example.myapplication.R
import com.example.myapplication.localization.AppTextResolver
import java.io.File

interface FileShareIntentFactory {
    fun createChooserIntent(context: Context, file: File): Intent

    fun createChooserIntent(context: Context, files: List<File>): Intent
}

class BleFileShareIntentFactory(
    private val authority: String,
    private val appTextResolver: AppTextResolver,
) : FileShareIntentFactory {
    override fun createChooserIntent(context: Context, file: File): Intent {
        return buildChooserIntent(
            context = context,
            files = listOf(file),
        )
    }

    override fun createChooserIntent(context: Context, files: List<File>): Intent {
        return buildChooserIntent(
            context = context,
            files = files,
        )
    }

    private fun buildChooserIntent(
        context: Context,
        files: List<File>,
    ): Intent {
        require(files.isNotEmpty()) { "At least one file is required for sharing" }

        val contentUris = files.map { file ->
            FileProvider.getUriForFile(
                context,
                authority,
                file.canonicalFile,
            )
        }
        val clipData = ClipData.newRawUri(files.first().name, contentUris.first()).apply {
            files.drop(1).zip(contentUris.drop(1)).forEach { (file, contentUri) ->
                addItem(ClipData.Item(contentUri))
            }
        }

        val shareIntent = if (files.size == 1) {
            Intent(Intent.ACTION_SEND).apply {
                type = mimeTypeFor(files.single())
                putExtra(Intent.EXTRA_STREAM, contentUris.single())
            }
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                type = "*/*"
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(contentUris))
            }
        }.apply {
            this.clipData = clipData
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        return Intent.createChooser(
            shareIntent,
            appTextResolver.getString(R.string.share_chooser_title),
        )
    }

    private fun mimeTypeFor(file: File): String {
        return when (file.extension.lowercase()) {
            "csv" -> "text/csv"
            "log" -> "text/plain"
            "zip" -> "application/zip"
            else -> "application/octet-stream"
        }
    }
}
