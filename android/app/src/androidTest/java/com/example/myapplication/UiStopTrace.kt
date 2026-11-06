package com.example.myapplication

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Rect
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.WindowInsets
import android.view.WindowManager
import android.view.inspector.WindowInspector
import android.view.inputmethod.InputMethodManager
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/** GO02 observation only: never changes keyboard, flags, settings or original failures. */
internal object UiStopTrace {
    private const val TAG = "WoonaUiStopTrace"
    private val primaries = ConcurrentHashMap.newKeySet<String>()
    private fun guarded(case: String, stage: String, record: () -> Unit) {
        try { record() } catch (failure: Throwable) {
            runCatching { Log.e(TAG, "TRACE_CAPTURE_FAILURE case=$case stage=$stage", failure) }
        }
    }
    private fun emit(case: String, stage: String, text: String) {
        val record = "t=${SystemClock.elapsedRealtimeNanos()} pid=${Process.myPid()} case=$case stage=$stage primaryBodyLogged=${case in primaries}\n$text\n"
        record.chunked(3000).forEachIndexed { part, chunk -> Log.i(TAG, "part=$part $chunk") }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val base = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")?.let(::File)
            ?: context.getExternalFilesDir(null) ?: context.filesDir
        base.mkdirs()
        File(base, "ui-stop-trace.txt").appendText(record)
    }
    fun primary(case: String, failure: Throwable) = guarded(case, "PRIMARY") {
        // Full original stack goes to logcat before any state inspection or file I/O.
        val raw = failure.stackTraceToString()
        raw.chunked(3000).forEachIndexed { part, chunk -> Log.e(TAG, "PRIMARY case=$case part=$part\n$chunk") }
        primaries.add(case)
        emit(case, "PRIMARY", raw)
    }
    fun beforeClose(case: String, stage: String = "PRE_CLOSE") = guarded(case, stage) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            guarded(case, "${stage}_MAIN") {
                val snapshotStartNs = SystemClock.elapsedRealtimeNanos()
                val roots = WindowInspector.getGlobalWindowViews()
                val host = roots.asSequence().mapNotNull { root ->
                    generateSequence(root.context) { (it as? ContextWrapper)?.baseContext?.takeIf { next -> next !== it } }
                        .filterIsInstance<Activity>().firstOrNull()
                }.firstOrNull() ?: ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).firstOrNull()
                val context = host ?: instrumentation.targetContext
                val config = context.resources.configuration
                val metrics = context.resources.displayMetrics
                val automation = instrumentation.uiAutomation
                val ime = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                emit(case, stage, buildString {
                    appendLine("snapshotStartNs=$snapshotStartNs")
                    appendLine("fontSystem=${Settings.System.getFloat(context.contentResolver, Settings.System.FONT_SCALE, 1f)} fontResources=${config.fontScale} orientation=${config.orientation} requested=${host?.requestedOrientation} display=${metrics.widthPixels}x${metrics.heightPixels} density=${metrics.densityDpi} flags=${automation.serviceInfo.flags} imeAccepting=${ime.isAcceptingText} imeFullscreen=${ime.isFullscreenMode}")
                    appendLine("host=${host?.javaClass?.name} finishing=${host?.isFinishing} destroyed=${host?.isDestroyed} decorFocus=${host?.window?.decorView?.hasWindowFocus()}")
                    roots.forEach { root ->
                        val point = IntArray(2).also(root::getLocationOnScreen)
                        val params = root.layoutParams as? WindowManager.LayoutParams
                        appendLine("root=${root.javaClass.name} token=${root.windowToken} bounds=${point.toList()}/${root.width}x${root.height} focus=${root.hasWindowFocus()} focusedView=${root.findFocus()?.javaClass?.name} type=${params?.type} softInput=${params?.softInputMode} imeVisible=${root.rootWindowInsets?.isVisible(WindowInsets.Type.ime())} imeInsets=${root.rootWindowInsets?.getInsets(WindowInsets.Type.ime())}")
                    }
                    automation.windows.forEach { window ->
                        val bounds = Rect().also(window::getBoundsInScreen)
                        appendLine("a11yWindow id=${window.id} type=${window.type} focused=${window.isFocused} active=${window.isActive} layer=${window.layer} bounds=$bounds")
                    }
                    appendLine("snapshotEndNs=${SystemClock.elapsedRealtimeNanos()}")
                })
            }
        }
    }
    fun v2(case: String, rule: ComposeContentTestRule) {
        beforeClose(case, "PRE_V2") // Direct window/font read; no keyboard operation.
        listOf(false, true).forEach { unmerged -> guarded(case, "V2_SEMANTICS_$unmerged") {
            val tree = rule.onRoot(useUnmergedTree = unmerged).printToString()
            check(tree.length <= 131072) { "TRACE_BOUND_EXCEEDED semantics chars=${tree.length}" }
            val root = rule.onRoot(useUnmergedTree = unmerged).fetchSemanticsNode().boundsInRoot
            val disconnect = rule.onAllNodesWithText("DISCONNECT", useUnmergedTree = unmerged)
                .fetchSemanticsNodes().map { it.boundsInRoot }
            emit(case, "V2_SEMANTICS_$unmerged", "rootBounds=$root disconnectBounds=$disconnect\n$tree")
        } }
    }
}
