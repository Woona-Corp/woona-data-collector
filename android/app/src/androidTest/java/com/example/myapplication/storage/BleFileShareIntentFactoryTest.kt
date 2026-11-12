package com.example.myapplication.storage

import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.localization.AppTextResolver
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class BleFileShareIntentFactoryTest {
    @Test fun sessionZipUsesZipMimeType() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val archive = File(context.cacheDir, "session-share-${System.nanoTime()}.zip").apply { writeText("fixture") }
        try {
            val factory = BleFileShareIntentFactory(
                authority = "${context.packageName}.provider",
                appTextResolver = AppTextResolver(context) { AppLanguage.ENGLISH },
            )
            val chooser = factory.createChooserIntent(context, archive)
            @Suppress("DEPRECATION")
            val share = requireNotNull(chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT))
            assertEquals(Intent.ACTION_SEND, share.action)
            assertEquals("application/zip", share.type)
        } finally {
            archive.delete()
        }
    }
}
