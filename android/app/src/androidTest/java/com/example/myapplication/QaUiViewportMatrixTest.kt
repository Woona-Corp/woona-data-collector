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
import org.junit.BeforeClass
import org.junit.AfterClass
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/** Uses real Android system font scaling: a Dialog has its own composition
 * density, so overriding LocalDensity outside a Dialog is not sufficient.
 *
 * DUAL RELEASE GATE: these checks prove complete token-editor/action visibility,
 * focus, value and selection, and conservative natural-height Notes cursor
 * interval containment. They do NOT replace independent rendered-pixel review. Review all 24 saved screenshots independently: all eight
 * server-ime masks/carets and all eight notes-ime final End/carets must be
 * visible. Compose 1.7 native character extras omit internal scroll offsets
 * and sometimes omit the whole array, so they are diagnostic evidence only. */
@RunWith(Parameterized::class)
class QaUiViewportMatrixTest(private val landscape: Boolean, private val font: Float, private val language: AppLanguage) {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    companion object {
        private const val IMMERSIVE_CONFIRMATIONS = "immersive_mode_confirmations"
        private var immersiveSnapshotTaken = false
        private var originalImmersiveConfirmation: String? = null

        /** Opt-in only for a disposable emulator. Set up before any Compose
         * rule launches its Activity, not by dismissing overlays mid-assertion.
         * No argument means no setting mutation and no skipped test cases. */
        @JvmStatic @BeforeClass
        fun confirmImmersiveOnboardingOnDisposableEmulator() {
            if (InstrumentationRegistry.getArguments().getString("woonaDisposableEmulator") != "true") return
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val automation = instrumentation.uiAutomation
            val qemu = android.os.ParcelFileDescriptor.AutoCloseInputStream(
                automation.executeShellCommand("getprop ro.kernel.qemu"),
            ).use { it.readBytes().toString(Charsets.UTF_8).trim() }
            check(qemu == "1") { "woonaDisposableEmulator=true requires ro.kernel.qemu=1; no settings were changed" }
            val resolver = instrumentation.targetContext.contentResolver
            originalImmersiveConfirmation = android.provider.Settings.Secure.getString(resolver, IMMERSIVE_CONFIRMATIONS)
            // Distinguish an absent setting from the literal string "null";
            // retain this guard even if the following write/readback fails.
            immersiveSnapshotTaken = true
            writeImmersiveConfirmation("confirmed")
        }

        @JvmStatic @AfterClass
        fun restoreImmersiveOnboardingAfterAllActivitiesDispose() {
            if (!immersiveSnapshotTaken) return
            writeImmersiveConfirmation(originalImmersiveConfirmation)
            immersiveSnapshotTaken = false
        }

        private fun writeImmersiveConfirmation(value: String?) {
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val automation = instrumentation.uiAutomation
            val resolver = instrumentation.targetContext.contentResolver
            automation.adoptShellPermissionIdentity(android.Manifest.permission.WRITE_SECURE_SETTINGS)
            try {
                // putString(null) deletes an originally absent setting.
                check(android.provider.Settings.Secure.putString(resolver, IMMERSIVE_CONFIRMATIONS, value)) {
                    "Could not write immersive onboarding test precondition"
                }
                assertEquals("Immersive onboarding setting readback", value,
                    android.provider.Settings.Secure.getString(resolver, IMMERSIVE_CONFIRMATIONS))
            } finally {
                automation.dropShellPermissionIdentity()
            }
        }

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
    /** Token: require the complete editor above the IME. Natural-height Notes:
     * prove zero internal scroll and contain the entire conservative cursor
     * interval in the clipped editor and native IME-safe window. Native glyph
     * extras remain diagnostic; all 24 screenshots still require visual review. */
    @Suppress("DEPRECATION")
    private fun focusedInput(expected: String, password: Boolean = false) {
        val editable = compose.onNode(isFocused() and hasSetTextAction())
        editable.assertIsFocused()
        val semantics = editable.fetchSemanticsNode().config
        assertEquals("Password semantics must match the editor type", password,
            semantics.contains(androidx.compose.ui.semantics.SemanticsProperties.Password))
        // PasswordVisualTransformation intentionally exposes only U+2022 to
        // accessibility. Require exact masking, never accept raw secret text.
        // The fake Save callback below separately proves the raw token value.
        val expectedDisplay = if (password) "\u2022".repeat(expected.length) else expected
        assertEquals("Focused editor must expose the exact expected display value", expectedDisplay,
            semantics[androidx.compose.ui.semantics.SemanticsProperties.EditableText].text)
        assertEquals("Collapsed caret must remain after the inserted text", androidx.compose.ui.text.TextRange(expected.length),
            semantics[androidx.compose.ui.semantics.SemanticsProperties.TextSelectionRange])
        val layouts = mutableListOf<TextLayoutResult>()
        editable.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertTrue("Focused editor must expose its text layout", layouts.isNotEmpty())
        // A merged field can also expose decoration/label layouts. Matching
        // length alone is unsafe ("New token" and nine mask glyphs both have
        // length nine). Only the exact displayed editor text proves its caret.
        val layoutKinds = layouts.map { result ->
            "length=${result.layoutInput.text.length},matchesEditor=${result.layoutInput.text.text == expectedDisplay}"
        }
        val matchingLayouts = layouts.filter { it.layoutInput.text.text == expectedDisplay }
        assertEquals("Exactly one layout must belong to the editable text, not a label: $layoutKinds", 1, matchingLayouts.size)
        val editorLayout = matchingLayouts.single()
        val last = expected.lastIndex
        val fullGlyph = editorLayout.getBoundingBox(last)
        assertTrue("Fixture ends with a visible glyph", fullGlyph.height > 0 && fullGlyph.width > 0)

        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        fun find(node: android.view.accessibility.AccessibilityNodeInfo?): android.view.accessibility.AccessibilityNodeInfo? {
            if (node == null) return null
            if (node.isEditable && node.isFocused) return node
            for (index in 0 until node.childCount) find(node.getChild(index))?.let { return it }
            return null
        }
        val windowAndEditor = automation.windows.asSequence()
            .filter { it.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            .mapNotNull { window -> find(window.root)?.let { window to it } }.firstOrNull()
        assertNotNull("Native accessibility must retain focused editable", windowAndEditor)
        val (window, nativeEditor) = requireNotNull(windowAndEditor)
        val key = android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_KEY
        val arguments = android.os.Bundle().apply {
            putInt(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_START_INDEX, last)
            putInt(android.view.accessibility.AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_LENGTH, 1)
        }
        val providerRefresh = runCatching { nativeEditor.refreshWithExtraData(key, arguments) }
        val glyphs = nativeEditor.extras.getParcelableArray(key)
        // Evidence only: never log editor text, token content or change focus/
        // scrolling to make a coordinate assertion pass. This distinguishes a
        // provider capability/coordinate issue from genuinely hidden text.
        val geometry = buildString {
            val composeEditor = editable.fetchSemanticsNode()
            appendLine("landscape=$landscape font=$font language=$language password=$password expectedLength=${expected.length}")
            appendLine("composeBounds=${composeEditor.boundsInRoot} composePosition=${composeEditor.positionInRoot} unclippedEditorSize=${composeEditor.layoutInfo.width}x${composeEditor.layoutInfo.height} layoutKinds=$layoutKinds layoutSize=${editorLayout.size} fullGlyph=$fullGlyph cursor=${editorLayout.getCursorRect(expected.length)}")
            if (semantics.contains(androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange)) {
                val axis = semantics[androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange]
                appendLine("editorVerticalScroll=${axis.value()} max=${axis.maxValue()} reversed=${axis.reverseScrolling}")
            }
            appendLine("nativeClass=${nativeEditor.className} editable=${nativeEditor.isEditable} focused=${nativeEditor.isFocused} password=${nativeEditor.isPassword} selection=${nativeEditor.textSelectionStart}..${nativeEditor.textSelectionEnd} textLength=${nativeEditor.text?.length}")
            appendLine("providerRefresh=${providerRefresh.getOrNull()} providerError=${providerRefresh.exceptionOrNull()?.javaClass?.simpleName} availableExtraData=${nativeEditor.availableExtraData} extrasKeys=${nativeEditor.extras.keySet().toList()} glyphs=${glyphs?.toList()}")
            appendLine("nativeEditorBounds=${android.graphics.Rect().also(nativeEditor::getBoundsInScreen)} nativeWindowBounds=${android.graphics.Rect().also(window::getBoundsInScreen)}")
            automation.windows.forEach { observed ->
                appendLine("nativeWindow type=${observed.type} focused=${observed.isFocused} bounds=${android.graphics.Rect().also(observed::getBoundsInScreen)}")
            }
        }
        val outputBase = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")?.let { java.io.File(it) }
            ?: InstrumentationRegistry.getInstrumentation().targetContext.filesDir
        java.io.File(outputBase, "focused-input-geometry.txt").apply { parentFile?.mkdirs(); appendText(geometry + "\n") }
        val composeEditor = editable.fetchSemanticsNode()
        // Unmerged ancestry retains scroll containers that merged editor semantics can skip.
        val unmergedEditor = compose.onNode(isFocused() and hasSetTextAction(), useUnmergedTree = true)
            .fetchSemanticsNode()
        // AccessibilityWindowInfo bounds are the visible window frame,
        // NOT the window-coordinate origin (status bars can be excluded).
        // Independently measure the focused Dialog decor's window->screen
        // translation; never derive it from the expected native editor.
        val (windowToScreen, decorBounds, mappedRoot) = compose.runOnIdle {
            val focusedViews = if (android.os.Build.VERSION.SDK_INT >= 29) {
                android.view.inspector.WindowInspector.getGlobalWindowViews().filter { it.hasWindowFocus() }
            } else throw AssertionError("Independent matrix window geometry requires API 29+")
            assertEquals("Exactly one decor must own window focus", 1, focusedViews.size)
            val decor = focusedViews.single()
            val screen = IntArray(2).also(decor::getLocationOnScreen)
            val inWindow = IntArray(2).also(decor::getLocationInWindow)
            val offset = androidx.compose.ui.geometry.Offset((screen[0] - inWindow[0]).toFloat(), (screen[1] - inWindow[1]).toFloat())
            val nativeDecor = android.graphics.RectF(screen[0].toFloat(), screen[1].toFloat(),
                (screen[0] + decor.width).toFloat(), (screen[1] + decor.height).toFloat())
            var rootInfo = composeEditor.layoutInfo
            while (rootInfo.parentInfo != null) rootInfo = requireNotNull(rootInfo.parentInfo)
            val rootCoordinates = rootInfo.coordinates
            assertTrue("Compose root coordinates must remain attached", rootCoordinates.isAttached)
            val rootOrigin = rootCoordinates.localToWindow(androidx.compose.ui.geometry.Offset.Zero) + offset
            val rootBounds = android.graphics.RectF(rootOrigin.x, rootOrigin.y,
                rootOrigin.x + rootCoordinates.size.width, rootOrigin.y + rootCoordinates.size.height)
            java.io.File(outputBase, "focused-input-geometry.txt").appendText(
                "focusedDecorCount=${focusedViews.size} decorScreen=${screen.toList()} decorInWindow=${inWindow.toList()} independentWindowToScreen=$offset nativeDecor=$nativeDecor mappedComposeRoot=$rootBounds\n",
            )
            // Observe all relevant PUBLIC scroll ancestors before any field-clip guard.
            // A range remainder is evidence, not proof of rounding, animation or a Core BIV defect.
            val scrollGeometry = buildString {
                var ancestor = unmergedEditor.parent
                var scrollCount = 0
                while (ancestor != null && scrollCount < 8) {
                    val current = ancestor
                    val axisKey = androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange
                    if (current.config.contains(axisKey)) {
                        val axis = current.config[axisKey]
                        val value = axis.value()
                        val maximum = axis.maxValue()
                        appendLine("scrollAncestor[$scrollCount] viewportBoundsInRoot=${current.boundsInRoot} viewportBoundsInWindow=${current.boundsInWindow} " +
                            "unclippedSemanticsSize=${current.size} unclippedLayoutSize=${current.layoutInfo.width}x${current.layoutInfo.height} " +
                            "positionInRoot=${current.positionInRoot} positionInWindow=${current.positionInWindow} " +
                            "verticalScrollValue=$value max=$maximum reverseScrolling=${axis.reverseScrolling} remaining=${maximum - value}")
                        scrollCount++
                    }
                    ancestor = current.parent
                }
                appendLine("scrollAncestorCount=$scrollCount limit=8 ancestorTraversalTruncated=${ancestor != null}; clip cause undetermined")
            }
            java.io.File(outputBase, "focused-input-geometry.txt").appendText(scrollGeometry)
            Triple(offset, nativeDecor, rootBounds)
        }
        // Validate all four ROOT edges against the independently measured
        // native decor. Accessibility editable bounds are NOT guaranteed to
        // equal rendering clip bounds: Compose 1.7 may overreport their top.
        assertEquals("Native decor/Compose root left must agree", decorBounds.left, mappedRoot.left, 1f)
        assertEquals("Native decor/Compose root top must agree", decorBounds.top, mappedRoot.top, 1f)
        assertEquals("Native decor/Compose root right must agree", decorBounds.right, mappedRoot.right, 1f)
        assertEquals("Native decor/Compose root bottom must agree", decorBounds.bottom, mappedRoot.bottom, 1f)
        val visible = android.graphics.Rect().also(window::getBoundsInScreen)
        val editorBounds = android.graphics.Rect().also(nativeEditor::getBoundsInScreen)
        assertFalse("Focused native editor must have nonempty bounds", editorBounds.isEmpty)
        assertEquals("Native editor must include its complete unclipped width\n$geometry",
            composeEditor.layoutInfo.width.toFloat(), editorBounds.width().toFloat(), 1f)
        assertEquals("Scroll container must not clip the focused editor width",
            composeEditor.layoutInfo.width.toFloat(), composeEditor.boundsInRoot.width, 1f)
        val padding = androidx.compose.material3.OutlinedTextFieldDefaults.contentPadding()
        val verticalPadding = with(editorLayout.layoutInput.density) {
            (padding.calculateTopPadding() + padding.calculateBottomPadding()).toPx()
        }
        assertTrue("Editor must fit a full glyph line plus Material vertical padding\n$geometry",
            editorBounds.height() >= fullGlyph.height + verticalPadding - 1f)
        val cursor = editorLayout.getCursorRect(expected.length)
        assertTrue("Caret line must fit the text layout width", cursor.left >= 0 && cursor.right <= editorLayout.size.width + 1f)
        if (password) {
            assertEquals("Native token editor must include its complete unclipped height\n$geometry",
                composeEditor.layoutInfo.height.toFloat(), editorBounds.height().toFloat(), 1f)
            assertEquals("Scroll container must not clip the token editor height",
                composeEditor.layoutInfo.height.toFloat(), composeEditor.boundsInRoot.height, 1f)
            assertEquals("Short token must remain a single visible text line", 1, editorLayout.lineCount)
            val horizontalPadding = with(editorLayout.layoutInput.density) {
                (padding.calculateLeftPadding(editorLayout.layoutInput.layoutDirection) +
                    padding.calculateRightPadding(editorLayout.layoutInput.layoutDirection)).toPx()
            }
            assertTrue("All nine mask glyphs and Material horizontal padding must fit", editorBounds.width() >= cursor.right + horizontalPadding - 1f)
        }
        val imeTop = automation.windows.filter { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            .minOfOrNull { android.graphics.Rect().also(it::getBoundsInScreen).top }
        assertNotNull("Focused input is measured with a visible native IME", imeTop)
        visible.bottom = minOf(visible.bottom, requireNotNull(imeTop))
        assertTrue("Visible editor $editorBounds inside IME-safe dialog $visible\n$geometry", visible.contains(editorBounds))
        if (!password) {
            // The production multiline BasicTextField is naturally measured by
            // the unbounded parent verticalScroll. With no internal maxLines /
            // height cap, Core's scroll maximum is zero. A hidden internal
            // viewport would fail this full natural-height assertion.
            val nonTextHeight = composeEditor.layoutInfo.height - editorLayout.size.height
            assertTrue("Notes must retain full natural paragraph height plus Material padding\n$geometry",
                nonTextHeight >= verticalPadding - 1f)
            assertEquals("Native focus must retain the exact caret start", expected.length, nativeEditor.textSelectionStart)
            assertEquals("Native focus must retain the exact caret end", expected.length, nativeEditor.textSelectionEnd)
            val clipped = composeEditor.boundsInWindow
            val mappedClip = android.graphics.RectF(
                clipped.left + windowToScreen.x, clipped.top + windowToScreen.y,
                clipped.right + windowToScreen.x, clipped.bottom + windowToScreen.y,
            )
            assertTrue("Actual Compose editor clip $mappedClip inside native editable $editorBounds", android.graphics.RectF(editorBounds).contains(mappedClip))
            val origin = composeEditor.positionInWindow
            // Material's unknown text-origin Y lies within [0, nonTextHeight].
            // This interval contains the complete final caret line for EVERY
            // such origin, not just an estimated padding/label offset.
            val cursorInterval = android.graphics.RectF(
                origin.x + windowToScreen.x, origin.y + cursor.top + windowToScreen.y,
                origin.x + composeEditor.layoutInfo.width + windowToScreen.x,
                origin.y + cursor.bottom + nonTextHeight + windowToScreen.y,
            )
            java.io.File(outputBase, "focused-input-geometry.txt").appendText(
                "naturalNotesNonTextHeight=$nonTextHeight mappedClip=$mappedClip nativeEditor=$editorBounds " +
                    "nativeMinusClipEdges=[${editorBounds.left - mappedClip.left},${editorBounds.top - mappedClip.top},${editorBounds.right - mappedClip.right},${editorBounds.bottom - mappedClip.bottom}] " +
                    "cursorInterval=$cursorInterval imeSafe=$visible\n\n",
            )
            assertTrue("Complete Notes cursor interval $cursorInterval inside clipped editor $mappedClip\n$geometry", mappedClip.contains(cursorInterval))
            assertTrue("Complete Notes cursor interval $cursorInterval inside native editable $editorBounds\n$geometry", android.graphics.RectF(editorBounds).contains(cursorInterval))
            assertTrue("Complete Notes cursor interval $cursorInterval inside IME-safe dialog $visible\n$geometry", android.graphics.RectF(visible).contains(cursorInterval))
        }
        java.io.File(outputBase, "manual-caret-review-required.txt").writeText(
            "AUTOMATED PASS IS NOT CARET VISUAL ACCEPTANCE. Independently review all 24 qa-ui-screens outputs. " +
                "All 8 server-ime images must show the token mask/caret and all 8 notes-ime images must show final End/caret, " +
                "with title/actions above the keyboard. A natural-height Notes label may scroll out with the form. " +
                "Native character extras are diagnostic only: " +
                "Compose 1.7 can omit the array or map raw text without its internal scroll transform.\n",
        )
    }
    private fun screenshot(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val base = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")?.let { java.io.File(it) }
            ?: instrumentation.targetContext.filesDir
        val dir = java.io.File(base, "qa-ui-screens").apply { mkdirs() }
        instrumentation.uiAutomation.takeScreenshot().let { image ->
            val output = java.io.File(dir, "$name-$landscape-$font-$language.png")
            try {
                output.outputStream().use { assertTrue("Screenshot encoding must succeed", image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)) }
                assertTrue("Required screenshot must be retained: ${output.name}", output.length() > 0)
            } finally { image.recycle() }
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
        var primaryFailure: Throwable? = null
        try {
            setSystemFont(font)
            compose.activity.requestedOrientation = if (landscape) ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            compose.waitUntil(10_000) { val v = compose.activity.findViewById<View>(android.R.id.content); (v.width > v.height) == landscape }
            // Geometry can update before rotation settles. Drain accessibility
            // events before creating the dialog; this is not a visibility retry
            // or a guarantee that compositor-only animation has finished.
            automation.waitForIdle(500, 10_000)
            var server by mutableStateOf(true)
            var savedToken: String? = null
            compose.setContent { MaterialTheme {
                if (server) ServerSettingsDialog(ServerSettings("https://example.invalid", "", "qa-device", true), language, {}, { _, token -> savedToken = token })
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
            focusedInput("synthetic", password = true)
            Thread.sleep(700) // Refocus/bring-into-view must not undo action visibility.
            action(cancel, false); action(save, false)
            focusedInput("synthetic", password = true)
            screenshot("server-ime")
            // Only after all visible-editing evidence is captured, prove the
            // original value reaches Save. This callback performs no I/O.
            compose.onNodeWithText(save).performClick()
            compose.runOnIdle { assertEquals("Save must receive the original typed token", "synthetic", savedToken) }
            androidx.test.espresso.Espresso.closeSoftKeyboard()
            compose.runOnIdle { server = false }
            compose.onNodeWithText(if (ru) "Примечания" else "Notes").performScrollTo().performClick().performTextInput("Notes\n".repeat(20) + "End")
            compose.waitUntil(10_000) { automation.windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD } }
            assertFalse("Notes must use regular IME", ime.isFullscreenMode)
            Thread.sleep(500)
            compose.onNodeWithText(if (ru) "Анкета сессии" else "Session questionnaire").assertIsDisplayed()
            action(cancel, false)
            action(if (ru) "Проверить и сохранить" else "Validate and save", false)
            focusedInput("Notes\n".repeat(20) + "End")
            Thread.sleep(700)
            action(cancel, false)
            action(if (ru) "Проверить и сохранить" else "Validate and save", false)
            focusedInput("Notes\n".repeat(20) + "End")
            screenshot("notes-ime")
        } catch (primary: Throwable) {
            primaryFailure = primary
            UiStopTrace.primary("QA[$landscape,$font,$language]", primary)
            // Capture the failing state before keyboard/orientation cleanup.
            runCatching { screenshot("primary-failure") }.onFailure { capture -> primary.addSuppressed(capture) }
            throw primary
        } finally {
            UiStopTrace.beforeClose("QA[$landscape,$font,$language]")
            restoreUiTestState(primaryFailure,
                { androidx.test.espresso.Espresso.closeSoftKeyboard() },
                { automation.serviceInfo = automation.serviceInfo.apply { this.flags = flags } },
                { compose.activity.restoreTestOrientation(orientation) },
                { setSystemFont(originalFont) },
            )
        }
    }
}
