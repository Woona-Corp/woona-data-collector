package com.example.myapplication.storage

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.app.ActivityOptionsCompat
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.example.myapplication.data.WoonaDatabase
import com.example.myapplication.localization.AppLanguage
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.ZipFile
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Explicit opt-in: uses the actual system picker, with only synthetic app-private files. */
@RunWith(AndroidJUnit4::class)
class PhysicalSafArchiveDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun savesAndVerifiesSyntheticArchiveThroughSystemPicker() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue("Explicit isolated physical SAF check required", InstrumentationRegistry.getArguments().getString("physicalSaf") == "true")
        val base = instrumentation.targetContext
        require(base.packageName.contains(".qa")) { "Only a separately installed synthetic QA package is allowed" }
        val sandbox = File(base.cacheDir, "physical-saf-${UUID.randomUUID()}").apply { mkdirs() }
        val files = File(sandbox, "files").apply { mkdirs() }
        val cache = File(sandbox, "cache").apply { mkdirs() }
        val isolated = object : ContextWrapper(base) {
            override fun getFilesDir(): File = files
            override fun getCacheDir(): File = cache
            override fun getApplicationContext(): Context = this
        }
        val resultUri = AtomicReference<Uri?>()
        val launcher = compose.activity.activityResultRegistry.register(
            "physical-saf-${UUID.randomUUID()}", ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            resultUri.set(result.data?.data)
            pendingRequest.get()?.let { (registry, code) -> registry.dispatchResult(code, result.resultCode, result.data) }
        }
        val owner = object : ActivityResultRegistryOwner {
            override val activityResultRegistry = object : ActivityResultRegistry() {
                override fun <I, O> onLaunch(code: Int, contract: ActivityResultContract<I, O>, input: I, options: ActivityOptionsCompat?) {
                    pendingRequest.set(this to code)
                    val intent = contract.createIntent(compose.activity, input)
                    assertEquals(Intent.ACTION_CREATE_DOCUMENT, intent.action)
                    intent.putExtra(Intent.EXTRA_TITLE, "Woona-QA-${UUID.randomUUID()}.zip")
                    intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI,
                        DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", "primary:Download"))
                    launcher.launch(intent)
                }
            }
        }
        try {
            WoonaDatabase(isolated).use { }
            val original = File(files, "Woona/recordings/source.bin").apply { parentFile!!.mkdirs(); writeText("synthetic original") }
            compose.setContent {
                CompositionLocalProvider(LocalContext provides isolated, LocalActivityResultRegistryOwner provides owner) {
                    CompleteArchiveCard(AppLanguage.ENGLISH, captureActive = false)
                }
            }
            compose.onNodeWithTag("archive.all.create").performClick()
            compose.waitUntil(30_000) { compose.onAllNodesWithTag("archive.all.save").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("archive.all.save").performClick()
            val automation = instrumentation.uiAutomation
            val deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(15)
            var clicked = false
            while (!clicked && System.nanoTime() < deadline) {
                val root = automation.rootInActiveWindow
                if (root?.packageName?.toString()?.endsWith(".documentsui") == true) {
                    val packageName = root.packageName.toString()
                    val breadcrumbs = root.findAccessibilityNodeInfosByViewId("$packageName:id/breadcrumb_text")
                    // Inspect the current breadcrumb, not a sidebar entry: never
                    // save to a remembered cloud provider or another folder.
                    val currentFolder = breadcrumbs.lastOrNull()?.text?.toString()
                    if (currentFolder in setOf("Download", "Downloads", "Загрузки")) {
                        val save = root.findAccessibilityNodeInfosByViewId("android:id/button1").singleOrNull()
                        if (save != null && save.isClickable && save.isEnabled) {
                            clicked = save.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK)
                        }
                    }
                }
                if (!clicked) Thread.sleep(100)
            }
            assertTrue("System picker did not show the local Downloads destination and Save action", clicked)
            compose.waitUntil(30_000) {
                try { compose.onAllNodesWithText("Archive saved to the selected location.").fetchSemanticsNodes().isNotEmpty() }
                catch (_: IllegalStateException) { false }
            }
            val uri = requireNotNull(resultUri.get())
            assertEquals("com.android.externalstorage.documents", uri.authority)
            val copied = File(sandbox, "verify.zip")
            base.contentResolver.openInputStream(uri)!!.use { input -> copied.outputStream().use { output -> input.copyTo(output) } }
            ZipFile(copied).use { zip ->
                assertNotNull(zip.getEntry("manifest.json"))
                assertNotNull(zip.getEntry("data/Woona/woona.sqlite"))
                assertEquals("synthetic original", zip.getInputStream(zip.getEntry("data/Woona/recordings/source.bin")).reader().readText())
            }
            assertEquals("synthetic original", original.readText())
        } finally {
            launcher.unregister()
            resultUri.get()?.let { uri ->
                // Delete only the unique document just created by this test.
                if (uri.authority == "com.android.externalstorage.documents") DocumentsContract.deleteDocument(base.contentResolver, uri)
            }
            pendingRequest.set(null)
            sandbox.deleteRecursively()
        }
    }

    private companion object {
        val pendingRequest = AtomicReference<Pair<ActivityResultRegistry, Int>?>(null)
    }
}
