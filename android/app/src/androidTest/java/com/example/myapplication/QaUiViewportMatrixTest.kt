package com.example.myapplication

import android.content.Context
import android.content.pm.ActivityInfo
import android.view.View
import android.view.accessibility.AccessibilityWindowInfo
import android.view.inputmethod.InputMethodManager
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.profile.SessionQuestionnaireDialog
import com.example.myapplication.sync.ServerSettings
import com.example.myapplication.sync.ServerSettingsDialog
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/** Uses real Android system font scaling: a Dialog has its own composition
 * density, so overriding LocalDensity outside a Dialog is not sufficient. */
@RunWith(Parameterized::class)
class QaUiViewportMatrixTest(private val landscape: Boolean, private val font: Float, private val language: AppLanguage) {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    companion object {
        @JvmStatic @Parameterized.Parameters(name = "landscape={0},font={1},language={2}")
        fun cases() = listOf(false, true).flatMap { landscape -> listOf(1.1f, 1.8f).flatMap { font ->
            listOf(AppLanguage.ENGLISH, AppLanguage.RUSSIAN).map { arrayOf<Any>(landscape, font, it) }
        } }
    }
    private fun action(label: String, scroll: Boolean) {
        val node = compose.onNodeWithText(label)
        if (scroll) node.performScrollTo()
        node.assertIsDisplayed()
        val layouts = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertTrue(layouts.isNotEmpty())
        assertEquals("Dialog must render with the requested system font scale", font, layouts.first().layoutInput.density.fontScale, 0.01f)
        layouts.forEach { result -> (0 until result.lineCount).forEach { line ->
            assertFalse("$label ellipsized", result.isLineEllipsized(line))
            assertTrue("$label glyph width", result.getLineRight(line) <= result.size.width + 1f)
            assertTrue("$label glyph height", result.getLineBottom(line) <= result.size.height + 1f)
        } }
        val bounds = compose.onNode(hasText(label) and hasClickAction()).fetchSemanticsNode().boundsInRoot
        assertTrue("$label target height $bounds", bounds.height >= 48 * compose.activity.resources.displayMetrics.density - 1)
        // Compose local bounds alone miss whole-window IME panning. Inspect
        // Android accessibility screen coordinates against the actual IME top.
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val imeTop = automation.windows.filter { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }.minOfOrNull { window ->
            android.graphics.Rect().also(window::getBoundsInScreen).top
        }
        fun find(node: android.view.accessibility.AccessibilityNodeInfo?): android.graphics.Rect? {
            if (node == null) return null
            if (node.text?.toString() == label) return android.graphics.Rect().also(node::getBoundsInScreen)
            for (index in 0 until node.childCount) find(node.getChild(index))?.let { return it }
            return null
        }
        val screenBounds = automation.windows.asSequence().filter { it.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            .mapNotNull { find(it.root) }.firstOrNull()
        assertNotNull("$label must exist in Android window accessibility", screenBounds)
        assertTrue("$label screen bounds $screenBounds above IME top=$imeTop", screenBounds!!.top >= 0 && screenBounds.bottom <= (imeTop ?: compose.activity.resources.displayMetrics.heightPixels))
    }
    private fun screenshot(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val dir = java.io.File(instrumentation.targetContext.filesDir, "qa-ui-screens").apply { mkdirs() }
        instrumentation.uiAutomation.takeScreenshot().let { image ->
            java.io.File(dir, "$name-$landscape-$font-$language.png").outputStream().use { image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
            image.recycle()
        }
    }
    @Test fun serverAndNotesActionsRemainReadableWithRegularIme() {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val flags = automation.serviceInfo.flags
        automation.serviceInfo = automation.serviceInfo.apply { this.flags = flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS }
        val orientation = compose.activity.requestedOrientation
        val originalFont = compose.activity.resources.configuration.fontScale
        fun setSystemFont(scale: Float) {
            android.os.ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand("settings put system font_scale $scale")).use { it.readBytes() }
            compose.waitUntil(10_000) { kotlin.math.abs(compose.activity.resources.configuration.fontScale - scale) < 0.01f }
        }
        try {
            setSystemFont(font)
            compose.activity.requestedOrientation = if (landscape) ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            compose.waitUntil(10_000) { val v = compose.activity.findViewById<View>(android.R.id.content); (v.width > v.height) == landscape }
            var server by mutableStateOf(true)
            compose.setContent { MaterialTheme {
                if (server) ServerSettingsDialog(ServerSettings("https://example.invalid", "", "qa-device", true), language, {}, { _, _ -> })
                else SessionQuestionnaireDialog(language, {}, {}, videoAllowed = false)
            } }
            val ru = language == AppLanguage.RUSSIAN
            val cancel = if (ru) "Отмена" else "Cancel"
            val save = if (ru) "Сохранить" else "Save"
            action(cancel, false); action(save, false)
            screenshot("server-no-ime")
            compose.onNodeWithText(if (ru) "Новый токен" else "New token").performScrollTo().performClick().performTextInput("synthetic")
            compose.waitUntil(10_000) { automation.windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD } }
            val ime = compose.activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            assertFalse("Must measure regular IME, not fullscreen extract", ime.isFullscreenMode)
            Thread.sleep(500)
            action(cancel, false); action(save, false)
            Thread.sleep(700) // Refocus/bring-into-view must not undo action visibility.
            action(cancel, false); action(save, false)
            screenshot("server-ime")
            androidx.test.espresso.Espresso.closeSoftKeyboard()
            compose.runOnIdle { server = false }
            compose.onNodeWithText(if (ru) "Примечания" else "Notes").performScrollTo().performClick().performTextInput("Notes\n".repeat(20))
            compose.waitUntil(10_000) { automation.windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD } }
            assertFalse("Notes must use regular IME", ime.isFullscreenMode)
            Thread.sleep(500)
            compose.onNodeWithText(if (ru) "Анкета сессии" else "Session questionnaire").assertIsDisplayed()
            action(cancel, false)
            action(if (ru) "Проверить и сохранить" else "Validate and save", false)
            screenshot("notes-ime")
        } catch (primary: Throwable) {
            UiStopTrace.primary("QA[$landscape,$font,$language]", primary)
            throw primary
        } finally {
            UiStopTrace.beforeClose("QA[$landscape,$font,$language]")
            androidx.test.espresso.Espresso.closeSoftKeyboard()
            automation.serviceInfo = automation.serviceInfo.apply { this.flags = flags }
            compose.activity.restoreTestOrientation(orientation)
            setSystemFont(originalFont)
        }
    }
}
