package com.example.myapplication.storage

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.printToString
import androidx.core.app.ActivityOptionsCompat
import androidx.core.content.FileProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.example.myapplication.data.WoonaDatabase
import com.example.myapplication.localization.AppLanguage
import java.io.File
import java.util.zip.ZipFile
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CompleteArchiveCardTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private lateinit var sandbox: File
    private lateinit var isolated: Context
    private lateinit var selected: File
    private lateinit var selectedUri: Uri

    @Before fun setup() {
        val base = ApplicationProvider.getApplicationContext<Context>()
        sandbox = File(base.cacheDir, "archive-ui-${System.nanoTime()}").apply { mkdirs() }
        val files = File(sandbox, "files").apply { mkdirs() }
        val cache = File(sandbox, "cache").apply { mkdirs() }
        isolated = object : ContextWrapper(base) {
            override fun getFilesDir(): File = files
            override fun getCacheDir(): File = cache
            override fun getApplicationContext(): Context = this
        }
        WoonaDatabase(isolated).use { }
        File(files, "Woona/recordings/source.bin").apply { parentFile!!.mkdirs(); writeText("source data") }
        selected = File(sandbox, "selected.zip").apply { createNewFile() }
        selectedUri = FileProvider.getUriForFile(base, "${base.packageName}.provider", selected)
    }

    @After fun cleanup() { sandbox.deleteRecursively() }

    @Test fun systemDocumentSelectionCanCancelFailAndRetryWithoutLosingArchive() {
        val results = listOf(null, Uri.parse("content://invalid.woona.test/failed.zip"), selectedUri)
        val intents = mutableListOf<Intent>()
        val owner = object : ActivityResultRegistryOwner {
            override val activityResultRegistry = object : ActivityResultRegistry() {
                override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>, input: I, options: ActivityOptionsCompat?) {
                    intents += contract.createIntent(compose.activity, input)
                    val result = results[intents.size - 1]
                    dispatchResult(requestCode, if (result == null) Activity.RESULT_CANCELED else Activity.RESULT_OK, Intent().setData(result))
                }
            }
        }
        compose.setContent {
            CompositionLocalProvider(LocalContext provides isolated, LocalActivityResultRegistryOwner provides owner) {
                CompleteArchiveCard(AppLanguage.ENGLISH, captureActive = false)
            }
        }
        compose.onNodeWithTag("archive.all.create").performClick()
        try {
            compose.waitUntil(30_000) {
                compose.onAllNodesWithTag("archive.all.save").fetchSemanticsNodes().isNotEmpty() ||
                    compose.onAllNodesWithText("Archive was not created", substring = true).fetchSemanticsNodes().isNotEmpty()
            }
        } catch (failure: Throwable) {
            throw AssertionError("Picker launches: ${intents.size}\n" + compose.onRoot(useUnmergedTree = true).printToString(), failure)
        }
        compose.onNodeWithTag("archive.all.save").assertIsDisplayed()
        compose.onNodeWithText("Share").assertIsDisplayed()

        // Cancelling the Android picker must leave the prepared archive available.
        compose.onNodeWithTag("archive.all.save").performClick()
        compose.onNodeWithTag("archive.all.save").assertIsDisplayed()
        assertEquals(Intent.ACTION_CREATE_DOCUMENT, intents[0].action)
        assertEquals("application/zip", intents[0].type)
        assertTrue(intents[0].getStringExtra(Intent.EXTRA_TITLE).orEmpty().endsWith(".zip"))

        // A provider that cannot be opened must leave the prepared archive for retry.
        compose.onNodeWithTag("archive.all.save").performClick()
        try {
            compose.waitUntil(30_000) { compose.onAllNodesWithText("Could not save the ZIP", substring = true).fetchSemanticsNodes().isNotEmpty() }
        } catch (failure: Throwable) {
            throw AssertionError("Picker launches: ${intents.size}\n" + compose.onRoot(useUnmergedTree = true).printToString(), failure)
        }
        compose.onNodeWithTag("archive.all.save").performClick()
        compose.waitUntil(30_000) { compose.onAllNodesWithText("Archive saved to the selected location.").fetchSemanticsNodes().isNotEmpty() }

        ZipFile(selected).use { zip ->
            assertNotNull(zip.getEntry("manifest.json"))
            assertNotNull(zip.getEntry("data/Woona/woona.sqlite"))
            assertEquals("source data", zip.getInputStream(zip.getEntry("data/Woona/recordings/source.bin")).reader().readText())
        }
        assertEquals("source data", File(isolated.filesDir, "Woona/recordings/source.bin").readText())
    }
}
