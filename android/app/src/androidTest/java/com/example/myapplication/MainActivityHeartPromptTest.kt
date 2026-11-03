package com.example.myapplication

import android.Manifest
import android.content.Context
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.myapplication.ble.*
import com.example.myapplication.data.*
import com.example.myapplication.feature.device.*
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.localization.AppLanguagePreferences
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit

/** Real MainActivity/SQLite/capture finalization, with only the BLE transport and packet writer faked. */
@RunWith(AndroidJUnit4::class)
class MainActivityHeartPromptTest {
    @get:Rule val compose=createEmptyComposeRule()
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrumentation.targetContext

    @Test fun heartStopOpensTheChangedRecordingAfterFreshHistoryAndNeverEditsAnOlderHeart() = withCapture("heart") { fixture ->
        ActivityScenario.launch(MainActivity::class.java).use {
            awaitRecordingHistory()
            compose.onNodeWithText("Activity and heart questionnaire").assertDoesNotExist()
            stopSession()
            awaitHeartEditor()
            val choices=compose.onAllNodesWithText("Unknown").fetchSemanticsNodes().size
            assertEquals(6,choices)
            repeat(choices) { index -> compose.onAllNodesWithText("Unknown")[index].performScrollTo().performClick() }
            compose.onNodeWithText("Validate and save").performClick()
            compose.waitUntil(10_000) { fixture.database.recording(fixture.current.id)?.questionnaire?.heartQuestionnaire != null }
            compose.waitForIdle()
            compose.onNodeWithText("Activity and heart questionnaire").assertDoesNotExist()
            assertNull(fixture.database.recording(fixture.old.id)?.questionnaire?.heartQuestionnaire)
            assertEquals(RecordingStatus.COMPLETED,fixture.database.recording(fixture.current.id)?.status)
        }
    }

    @Test fun activityStopDoesNotOpenAnUnrelatedUnfilledHeartQuestionnaire() = withCapture("activity") { fixture ->
        ActivityScenario.launch(MainActivity::class.java).use {
            awaitRecordingHistory()
            stopSession()
            compose.waitUntil(10_000) { fixture.database.recording(fixture.current.id)?.status==RecordingStatus.COMPLETED }
            compose.onNodeWithTag("tab.recordings").performClick()
            compose.waitUntil(10_000) { compose.onAllNodesWithText("Capture: recording",substring=true).fetchSemanticsNodes().isEmpty() }
            compose.onNodeWithText("Activity and heart questionnaire").assertDoesNotExist()
            assertNull(fixture.database.recording(fixture.old.id)?.questionnaire?.heartQuestionnaire)
        }
    }

    @Test fun browsingAndRefreshingPersistedHeartHistoryNeverCreatesARecordingChangePrompt() = withCapture("activity") { fixture ->
        instrumentation.runOnMainSync { fixture.controller.onDisconnectRequested() }
        repeat(9) { fixture.completedHeart("Old browse $it") }
        ActivityScenario.launch(MainActivity::class.java).use {
            awaitReady()
            compose.onNodeWithTag("tab.recordings").performClick()
            compose.waitUntil(10_000) { compose.onAllNodesWithText("Open history").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Open history").performClick()
            compose.waitUntil(10_000) { compose.onAllNodesWithText("Shown 11 of 11").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Activity and heart questionnaire").assertDoesNotExist()
            compose.onNodeWithText("Refresh history").performClick()
            compose.waitUntil(10_000) { compose.onAllNodesWithText("Loading recordings…").fetchSemanticsNodes().isEmpty() }
            compose.onNodeWithText("Activity and heart questionnaire").assertDoesNotExist()
        }
    }

    @Test fun pendingHeartStopSurvivesRecreationWhileItsHistoryReadIsQueued() = withCapture("heart") { fixture ->
        val release=CountDownLatch(1)
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            try {
                awaitRecordingHistory()
                val blocked=CountDownLatch(1)
                scenario.onActivity { activity ->
                    val field=MainActivity::class.java.getDeclaredField("backgroundExecutor\$delegate").apply {isAccessible=true}
                    ((field.get(activity) as Lazy<*>).value as ExecutorService).execute { blocked.countDown();try {release.await()} catch(interrupted:InterruptedException) {Thread.currentThread().interrupt()} }
                }
                assertTrue(blocked.await(2,TimeUnit.SECONDS))
                stopSession()
                compose.waitUntil(10_000) { fixture.database.recording(fixture.current.id)?.status==RecordingStatus.COMPLETED }
                compose.waitForIdle()
                compose.onNodeWithText("Activity and heart questionnaire").assertDoesNotExist()
                scenario.recreate()
                release.countDown()
                awaitReady()
                awaitHeartEditor()
            } finally {release.countDown()}
        }
    }

    @Test fun recreationDuringRetirementTransactionKeepsDatabaseAndHeartPrompt() = withCapture("heart") { fixture ->
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val marker = UUID.randomUUID().toString().replace("-", "").repeat(2)
        val helper = ActivityDatabase.get(context)
        val db = helper.writableDatabase
        db.setCustomScalarFunction("woona_test_stop_gate") {
            entered.countDown()
            release.await(20, TimeUnit.SECONDS)
            "released"
        }
        db.execSQL("INSERT INTO deferred_retirements(kind,id_sha256,received_at_utc) VALUES('recording',?,?)", arrayOf(marker, "2026-01-01T00:00:00Z"))
        db.execSQL("CREATE TEMP TRIGGER woona_test_stop_gate BEFORE DELETE ON deferred_retirements BEGIN SELECT woona_test_stop_gate('wait'); END")
        try {
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                awaitRecordingHistory()
                stopSession()
                assertTrue("Stop cleanup did not enter its SQLite transaction", entered.await(15, TimeUnit.SECONDS))
                scenario.recreate()
                assertTrue("Activity destruction closed the database during cleanup", db.isOpen)
                release.countDown()
                awaitReady()
                awaitHeartEditor()
                assertEquals(RecordingStatus.COMPLETED, fixture.database.recording(fixture.current.id)?.status)
                assertNull(fixture.database.recording(fixture.old.id)?.questionnaire?.heartQuestionnaire)
                assertTrue(File(fixture.database.recordingDirectory(fixture.current.relativeDirectory), "packets.bin").isFile)
            }
        } finally {
            release.countDown()
            db.execSQL("DROP TRIGGER IF EXISTS temp.woona_test_stop_gate")
            db.execSQL("DELETE FROM deferred_retirements WHERE id_sha256=?", arrayOf(marker))
        }
    }

    @Test fun heartPromptIntentIsDurableBeforeTerminalRecordingCommit() = withCapture("heart") { fixture ->
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val db = fixture.database.writableDatabase
        db.setCustomScalarFunction("woona_test_finish_gate") {
            entered.countDown()
            release.await(20, TimeUnit.SECONDS)
            "released"
        }
        db.execSQL("CREATE TEMP TRIGGER woona_test_finish_gate BEFORE UPDATE OF status ON recordings WHEN old.id='${fixture.current.id}' AND new.status IN ('completed','interrupted','failed') BEGIN SELECT woona_test_finish_gate('wait'); END")
        try {
            ActivityScenario.launch(MainActivity::class.java).use {
                awaitRecordingHistory()
                stopSession()
                assertTrue("Recording did not reach terminal transaction", entered.await(15, TimeUnit.SECONDS))
                assertTrue("Pending prompt was not persisted before the terminal commit", fixture.current.id in PendingHeartPrompts(context).ids())
                assertTrue(File(fixture.database.recordingDirectory(fixture.current.relativeDirectory), "packets.bin").isFile)
                release.countDown()
                awaitHeartEditor()
            }
        } finally {
            release.countDown()
            db.execSQL("DROP TRIGGER IF EXISTS temp.woona_test_finish_gate")
        }
    }

    @Test fun concurrentStopMustWaitForDisconnectFinalizationBeforePacketTeardown() = withCapture("heart") { fixture ->
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        fixture.packets.onFinish = {
            entered.countDown()
            release.await(10, TimeUnit.SECONDS)
            true
        }
        val bleCallback = Thread { fixture.controller.onBleStateChanged(BleSessionState.DISCONNECTED) }
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            val stopCount = fixture.packets.stopCount.get()
            bleCallback.start()
            assertTrue("Unexpected disconnect did not start draining", entered.await(5, TimeUnit.SECONDS))
            val outcome = fixture.controller.requestDisconnect(executor)
            assertSame(outcome, fixture.controller.requestDisconnect(executor))
            executor.submit {}.get(5, TimeUnit.SECONDS)
            assertFalse("Stop completed while packet drain was blocked", outcome.isDone)
            assertEquals("Concurrent stop invoked packet teardown before the drain finished", stopCount, fixture.packets.stopCount.get())
            release.countDown()
            outcome.get(10, TimeUnit.SECONDS)
            assertEquals(stopCount + 1, fixture.packets.stopCount.get())
            assertEquals(RecordingStatus.INTERRUPTED, fixture.database.recording(fixture.current.id)?.status)
        } finally {
            release.countDown()
            bleCallback.join(10_000)
            executor.shutdownNow()
        }
    }

    @Test fun queuedStopBlocksStartingCaptureBeforeItsExecutorRuns() = withCapture("activity", startCapture = false) { fixture ->
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            executor.execute { entered.countDown(); release.await(10, TimeUnit.SECONDS) }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val outcome = fixture.controller.requestDisconnect(executor)
            instrumentation.runOnMainSync { fixture.controller.startSynchronizedSession() }
            assertEquals("A queued stop must keep capture from starting", RecordingStatus.PREPARING, fixture.database.recording(fixture.current.id)?.status)
            assertFalse(outcome.isDone)
            release.countDown()
            outcome.get(10, TimeUnit.SECONDS)
        } finally { release.countDown(); executor.shutdownNow() }
    }

    @Test fun polarReadyDuringFinalizationCannotRestartOrChangeCapturedSamples() = withCapture("activity") { fixture ->
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        fixture.packets.onFinish = { entered.countDown(); release.await(10, TimeUnit.SECONDS); true }
        try {
            instrumentation.runOnMainSync { fixture.controller.onPolarStatusChanged(PolarStatus(state = PolarConnectionState.READY)) }
            fixture.controller.onPolarHeartRate(com.example.myapplication.protocol.PolarHeartRateFrame(72, listOf(800)), 1_000L)
            val outcome = fixture.controller.onDisconnectRequested()
            assertTrue("Finalization did not reach the blocked packet drain", entered.await(5, TimeUnit.SECONDS))
            val hr = File(fixture.database.recordingDirectory(fixture.current.relativeDirectory), "polar_hr.csv")
            val captured = hr.readBytes()
            assertTrue(String(captured).contains(",72,800"))
            instrumentation.runOnMainSync { fixture.controller.onPolarStatusChanged(PolarStatus(state = PolarConnectionState.READY)) }
            fixture.controller.onPolarHeartRate(com.example.myapplication.protocol.PolarHeartRateFrame(99, listOf(600)), 2_000L)
            val field = DeviceFeatureController::class.java.getDeclaredField("polarFileStore").apply { isAccessible = true }
            (field.get(fixture.controller) as com.example.myapplication.storage.PolarCsvFileStore).flush()
            assertArrayEquals("A delayed READY callback must not reopen the Polar files", captured, hr.readBytes())
            release.countDown()
            outcome.get(10, TimeUnit.SECONDS)
            assertArrayEquals(captured, hr.readBytes())
        } finally { release.countDown(); fixture.packets.onFinish = null }
    }

    @Test fun polarReadyAfterUnexpectedFinalizationFailureCannotReopenFiles() = withCapture("activity") { fixture ->
        val reached = CountDownLatch(1)
        try {
            instrumentation.runOnMainSync { fixture.controller.onPolarStatusChanged(PolarStatus(state = PolarConnectionState.READY)) }
            fixture.controller.onPolarHeartRate(com.example.myapplication.protocol.PolarHeartRateFrame(72, listOf(800)), 1_000L)
            fixture.controller.setOnRecordingFinalizing { reached.countDown(); throw java.io.IOException("Injected finalization failure") }
            fixture.controller.onBleStateChanged(BleSessionState.DISCONNECTED)
            assertTrue(reached.await(5, TimeUnit.SECONDS))
            val finalizing = DeviceFeatureController::class.java.getDeclaredField("recordingFinalizing").apply { isAccessible = true }
            compose.waitUntil(10_000) { !finalizing.getBoolean(fixture.controller) }
            val storeField = DeviceFeatureController::class.java.getDeclaredField("polarFileStore").apply { isAccessible = true }
            val store = storeField.get(fixture.controller) as com.example.myapplication.storage.PolarCsvFileStore
            val streams = com.example.myapplication.storage.PolarCsvFileStore::class.java.getDeclaredField("streams").apply { isAccessible = true }
            val hr = File(fixture.database.recordingDirectory(fixture.current.relativeDirectory), "polar_hr.csv")
            val captured = hr.readBytes()
            instrumentation.runOnMainSync { fixture.controller.onPolarStatusChanged(PolarStatus(state = PolarConnectionState.READY)) }
            fixture.controller.onPolarHeartRate(com.example.myapplication.protocol.PolarHeartRateFrame(99, listOf(600)), 2_000L)
            assertTrue("A failed stop must not reopen Polar streams", (streams.get(store) as List<*>).isEmpty())
            assertArrayEquals(captured, hr.readBytes())
        } finally { fixture.controller.setOnRecordingFinalizing {} }
    }

    @Test fun polarFlushFailureMarksCaptureFailedAndRetainsOriginalFiles() {
        val writes = java.util.concurrent.atomic.AtomicInteger()
        val validPacket = byteArrayOf(
            0x33, 0x99.toByte(), 0xAA.toByte(), 0x55, 24, 0, 1, 1, 0, 0, 0, 50, 0, 0, 0, 0,
            2, 1, 1, 0, 0, 0, 10, 0,
        )
        withCapture("activity", packetBytes = validPacket, polarStoreFactory = {
            com.example.myapplication.storage.PolarCsvFileStore { file ->
                val output = java.io.FileOutputStream(file, true)
                object : java.io.OutputStream() {
                    override fun write(value: Int) = output.write(value)
                    override fun write(bytes: ByteArray, offset: Int, length: Int) {
                        if (file.name == "polar_hr.csv") {
                            writes.incrementAndGet()
                            output.write(bytes, offset, minOf(3, length))
                            throw java.io.IOException("Injected partial Polar write")
                        }
                        output.write(bytes, offset, length)
                    }
                    override fun close() = output.close()
                }
            }
        }) { fixture ->
            instrumentation.runOnMainSync { fixture.controller.onPolarStatusChanged(PolarStatus(state = PolarConnectionState.READY)) }
            fixture.controller.onPolarHeartRate(com.example.myapplication.protocol.PolarHeartRateFrame(72, listOf(800)), 1_000L)
            fixture.controller.onDisconnectRequested().get(15, TimeUnit.SECONDS)
            val result = requireNotNull(fixture.database.recording(fixture.current.id))
            assertEquals(RecordingStatus.FAILED, result.status)
            assertEquals("polar_persistence_failed", result.captureErrorCode)
            assertEquals("Partial writes must not be replayed", 1, writes.get())
            val dir = fixture.database.recordingDirectory(fixture.current.relativeDirectory)
            assertArrayEquals(validPacket, File(dir, "packets.bin").readBytes())
            val polarFile = File(dir, "polar_hr.csv")
            assertTrue(polarFile.isFile)
            val exportDir = File(context.cacheDir, "polar-failed-export-${UUID.randomUUID()}")
            try {
                val archive = requireNotNull(fixture.controller.createSessionArchive(exportDir))
                java.util.zip.ZipFile(archive).use { zip ->
                    assertArrayEquals(polarFile.readBytes(), zip.getInputStream(requireNotNull(zip.getEntry("polar_hr.csv"))).readBytes())
                    assertArrayEquals(validPacket, zip.getInputStream(requireNotNull(zip.getEntry("packets_snapshot_packet.bin"))).readBytes())
                    assertTrue(zip.getInputStream(requireNotNull(zip.getEntry("manifest.json"))).bufferedReader().readText().contains("\"status\":\"failed\""))
                }
            } finally { exportDir.deleteRecursively() }
            var created = false
            try {
                fixture.controller.createRecordingSession { created = true; fixture.current }
                fail("Polar storage failure requires a controller restart")
            } catch (_: IllegalStateException) { }
            assertFalse(created)
            val previousIdentity = fixture.controller.captureIdentity()
            try {
                fixture.controller.beginRecordingSession(fixture.current.copy(id = UUID.randomUUID().toString()))
                fail("Direct begin must also reject a failed Polar store")
            } catch (_: IllegalStateException) { }
            assertEquals(previousIdentity, fixture.controller.captureIdentity())
        }
    }

    @Test fun admittedPolarCallbackIsDrainedBeforeFinalization() = withCapture("activity") { fixture ->
        instrumentation.runOnMainSync { fixture.controller.onPolarStatusChanged(PolarStatus(state = PolarConnectionState.READY)) }
        val storeField = DeviceFeatureController::class.java.getDeclaredField("polarFileStore").apply { isAccessible = true }
        val pendingField = DeviceFeatureController::class.java.getDeclaredField("pendingPolarCallbacks").apply { isAccessible = true }
        val store = storeField.get(fixture.controller) as com.example.myapplication.storage.PolarCsvFileStore
        lateinit var callback: Thread
        lateinit var outcome: java.util.concurrent.CompletableFuture<Unit>
        synchronized(store) {
            callback = Thread { fixture.controller.onPolarHeartRate(com.example.myapplication.protocol.PolarHeartRateFrame(72, listOf(800)), 1_000L) }
            callback.start()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (synchronized(fixture.controller) { pendingField.getInt(fixture.controller) } == 0 && System.nanoTime() < deadline) Thread.sleep(10)
            assertEquals(1, synchronized(fixture.controller) { pendingField.getInt(fixture.controller) })
            outcome = fixture.controller.onDisconnectRequested()
            Thread.sleep(500)
            assertFalse("Stop must wait for the already-admitted callback", outcome.isDone)
        }
        callback.join(5_000)
        outcome.get(15, TimeUnit.SECONDS)
        val hr = File(fixture.database.recordingDirectory(fixture.current.relativeDirectory), "polar_hr.csv")
        assertTrue(hr.readText().contains(",72,800"))
        assertEquals(RecordingStatus.COMPLETED, fixture.database.recording(fixture.current.id)?.status)
    }

    @Test fun polarFrameFromPreviousRecordingIsRejectedBeforeNewFileAdmission() = withCapture("activity") { fixture ->
        fixture.controller.onDisconnectRequested().get(15, TimeUnit.SECONDS)
        val next = fixture.controller.createRecordingSession {
            fixture.database.beginRecording(fixture.dogId, RecordingSource.LIVE, questionnaire("Next Polar capture", "activity"))
        }
        instrumentation.runOnMainSync {
            fixture.controller.onConnectRequested("00:11:22:33:44:55")
            fixture.ble.listener.onStateChanged(BleSessionState.CONNECTED)
            fixture.ble.listener.onCaptureReady()
        }
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            fixture.controller.startSynchronizedSession()
            fixture.controller.onPolarStatusChanged(PolarStatus(state = PolarConnectionState.READY))
        }
        assertEquals(RecordingStatus.RECORDING, fixture.database.recording(next.id)?.status)
        val stale = com.example.myapplication.protocol.PolarHeartRateFrame(99, listOf(600))
        val current = com.example.myapplication.protocol.PolarHeartRateFrame(72, listOf(800))
        fixture.controller.onPolarHeartRate(stale, 1_000L, fixture.current.id)
        fixture.controller.onPolarHeartRate(current, 2_000L, next.id)
        val field = DeviceFeatureController::class.java.getDeclaredField("polarFileStore").apply { isAccessible = true }
        (field.get(fixture.controller) as com.example.myapplication.storage.PolarCsvFileStore).flush()
        val hr = File(fixture.database.recordingDirectory(next.relativeDirectory), "polar_hr.csv").readText()
        assertFalse("A late Polar sample contaminated B", hr.contains(",99,600"))
        assertTrue("A current Polar sample should be recorded", hr.contains(",72,800"))
    }

    @Test fun polarOpenFailureRemainsFailedWhenUiThreadIsBlocked() {
        withCapture("activity", polarStoreFactory = {
            com.example.myapplication.storage.PolarCsvFileStore { file ->
                if (file.name == "polar_ecg.csv") throw java.io.IOException("Injected Polar open failure")
                java.io.FileOutputStream(file, true)
            }
        }) { fixture ->
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            android.os.Handler(android.os.Looper.getMainLooper()).post { entered.countDown(); release.await(15, TimeUnit.SECONDS) }
            try {
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                val callback = Thread { fixture.controller.onPolarStatusChanged(PolarStatus(state = PolarConnectionState.READY)) }
                callback.start()
                callback.join(5_000)
                assertFalse("Polar callback did not return", callback.isAlive)
                val outcome = fixture.controller.onDisconnectRequested()
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
                while (fixture.database.recording(fixture.current.id)?.status != RecordingStatus.FAILED && System.nanoTime() < deadline) Thread.sleep(25)
                val result = requireNotNull(fixture.database.recording(fixture.current.id))
                assertEquals(RecordingStatus.FAILED, result.status)
                assertEquals("polar_persistence_failed", result.captureErrorCode)
                release.countDown()
                outcome.get(10, TimeUnit.SECONDS)
            } finally { release.countDown() }
        }
    }

    @Test fun terminalPriorityIsReappliedAfterSealedAttemptIsRetried() = withCapture("activity") { fixture ->
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        try {
            fixture.controller.setOnRecordingFinalizing { entered.countDown(); release.await(10, TimeUnit.SECONDS) }
            val outcome = fixture.controller.onDisconnectRequested()
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val requestField = DeviceFeatureController::class.java.getDeclaredField("finalizationRequest").apply { isAccessible = true }
            val request = requireNotNull(synchronized(fixture.controller) { requestField.get(fixture.controller) })
            val sealed = request.javaClass.getDeclaredField("statusSealed").apply { isAccessible = true }
            val status = request.javaClass.getDeclaredField("status").apply { isAccessible = true }
            // Reproduce the state while a commit is sealed, then its lock-error
            // handler clearing the seal before the next attempt.
            synchronized(fixture.controller) { sealed.setBoolean(request, true) }
            fixture.controller.onBleStateChanged(BleSessionState.FAILED)
            synchronized(fixture.controller) {
                assertEquals(RecordingStatus.COMPLETED, status.get(request))
                sealed.setBoolean(request, false)
            }
            release.countDown()
            outcome.get(15, TimeUnit.SECONDS)
            assertEquals(RecordingStatus.FAILED, fixture.database.recording(fixture.current.id)?.status)
        } finally { release.countDown(); fixture.controller.setOnRecordingFinalizing {} }
    }

    @Test fun failedTerminalIntentSurvivesAnErrorAndLaterStopRetry() = withCapture("activity") { fixture ->
        val reached = CountDownLatch(1)
        try {
            fixture.controller.setOnRecordingFinalizing { reached.countDown(); throw java.io.IOException("Injected first finalization failure") }
            fixture.controller.onSessionError("Injected capture failure")
            assertTrue(reached.await(5, TimeUnit.SECONDS))
            val finalizing = DeviceFeatureController::class.java.getDeclaredField("recordingFinalizing").apply { isAccessible = true }
            compose.waitUntil(10_000) { !finalizing.getBoolean(fixture.controller) }
            assertEquals(RecordingStatus.RECORDING, fixture.database.recording(fixture.current.id)?.status)
            fixture.controller.setOnRecordingFinalizing {}
            fixture.controller.onDisconnectRequested().get(15, TimeUnit.SECONDS)
            assertEquals(RecordingStatus.FAILED, fixture.database.recording(fixture.current.id)?.status)
        } finally { fixture.controller.setOnRecordingFinalizing {} }
    }

    @Test fun cameraStopWaitDoesNotBlockMainThreadFailureOrAnotherStop() = withCapture("activity") { fixture ->
        val field = DeviceFeatureController::class.java.getDeclaredField("videoRecorder").apply { isAccessible = true }
        val recorder = field.get(fixture.controller) as com.example.myapplication.video.AndroidVideoRecorder
        val handlerField = recorder.javaClass.getDeclaredField("cameraHandler").apply { isAccessible = true }
        val active = recorder.javaClass.getDeclaredField("active").apply { isAccessible = true }
        val stopRequested = recorder.javaClass.getDeclaredField("stopRequested").apply { isAccessible = true }
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val handled = CountDownLatch(1)
        val concurrentStop = java.util.concurrent.atomic.AtomicReference<java.util.concurrent.CompletableFuture<Unit>>()
        val handler = handlerField.get(recorder) as android.os.Handler
        handler.post { entered.countDown(); release.await(15, TimeUnit.SECONDS) }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            active.setBoolean(recorder, true)
            val stop = fixture.controller.onDisconnectRequested()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (!stopRequested.getBoolean(recorder) && System.nanoTime() < deadline) Thread.yield()
            assertTrue("Camera stop was not requested", stopRequested.getBoolean(recorder))
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                try {
                    fixture.controller.onSessionError("Injected BLE failure")
                    concurrentStop.set(fixture.controller.onDisconnectRequested())
                } finally { handled.countDown() }
            }
            assertTrue("Main thread waited for camera stop while holding the controller monitor", handled.await(2, TimeUnit.SECONDS))
            assertSame(stop, concurrentStop.get())
            assertFalse(stop.isDone)
            release.countDown()
            stop.get(15, TimeUnit.SECONDS)
            assertEquals(RecordingStatus.FAILED, fixture.database.recording(fixture.current.id)?.status)
            assertArrayEquals(byteArrayOf(1, 2, 3), File(fixture.database.recordingDirectory(fixture.current.relativeDirectory), "packets.bin").readBytes())
        } finally { release.countDown() }
    }

    @Test fun sessionFailureSurvivesDatabaseErrorDuringStopAndRetry() = withCapture("activity") { fixture ->
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val trigger = "reject_capture_error_${UUID.randomUUID().toString().replace("-", "")}"
        val db = fixture.database.writableDatabase
        db.execSQL("CREATE TRIGGER $trigger BEFORE UPDATE OF capture_error_code ON recordings BEGIN SELECT RAISE(ABORT,'synthetic error persistence failure'); END")
        fixture.packets.onFinish = { entered.countDown(); release.await(10, TimeUnit.SECONDS); true }
        try {
            val stop = fixture.controller.onDisconnectRequested()
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            instrumentation.runOnMainSync { fixture.controller.onSessionError("Injected BLE failure") }
            release.countDown()
            try {
                stop.get(15, TimeUnit.SECONDS)
                fail("Finalization must not succeed when the error cannot be persisted")
            } catch (_: java.util.concurrent.ExecutionException) { }
            assertEquals(RecordingStatus.RECORDING, fixture.database.recording(fixture.current.id)?.status)
            assertArrayEquals(byteArrayOf(1, 2, 3), File(fixture.database.recordingDirectory(fixture.current.relativeDirectory), "packets.bin").readBytes())
            db.execSQL("DROP TRIGGER $trigger")
            fixture.controller.onDisconnectRequested().get(15, TimeUnit.SECONDS)
            val result = requireNotNull(fixture.database.recording(fixture.current.id))
            assertEquals(RecordingStatus.FAILED, result.status)
            assertEquals("gatt_error", result.captureErrorCode)
        } finally {
            release.countDown()
            fixture.packets.onFinish = null
            db.execSQL("DROP TRIGGER IF EXISTS $trigger")
        }
    }

    @Test fun polarOpenFailureIsHandledAsFailedCaptureWithoutCrashingCallback() {
        withCapture("activity", polarStoreFactory = {
            com.example.myapplication.storage.PolarCsvFileStore { file ->
                if (file.name == "polar_ecg.csv") throw java.io.IOException("Injected Polar open failure")
                java.io.FileOutputStream(file, true)
            }
        }) { fixture ->
            instrumentation.runOnMainSync { fixture.controller.onPolarStatusChanged(PolarStatus(state = PolarConnectionState.READY)) }
            compose.waitUntil(15_000) { fixture.database.recording(fixture.current.id)?.status == RecordingStatus.FAILED }
            val result = requireNotNull(fixture.database.recording(fixture.current.id))
            assertEquals("polar_persistence_failed", result.captureErrorCode)
            assertArrayEquals(byteArrayOf(1, 2, 3), File(fixture.database.recordingDirectory(result.relativeDirectory), "packets.bin").readBytes())
        }
    }

    @Test fun queueOverflowCannotCommitCompletedWhileMainCallbackIsBlocked() = withCapture("activity") { fixture ->
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        fixture.packets.dropped.set(1)
        android.os.Handler(android.os.Looper.getMainLooper()).post { entered.countDown(); release.await(15, TimeUnit.SECONDS) }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val stop = fixture.controller.onDisconnectRequested()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
            var status = fixture.database.recording(fixture.current.id)?.status
            while (status != RecordingStatus.FAILED && System.nanoTime() < deadline) {
                Thread.sleep(20)
                status = fixture.database.recording(fixture.current.id)?.status
            }
            val result = requireNotNull(fixture.database.recording(fixture.current.id))
            assertEquals(RecordingStatus.FAILED, result.status)
            assertEquals("queue_overflow", result.captureErrorCode)
            assertFalse("UI teardown should still be pending", stop.isDone)
            assertArrayEquals(byteArrayOf(1, 2, 3), File(fixture.database.recordingDirectory(fixture.current.relativeDirectory), "packets.bin").readBytes())
            release.countDown()
            stop.get(15, TimeUnit.SECONDS)
        } finally { release.countDown() }
    }

    @Test fun captureFailureDuringStopPromotesFinalStatusToFailed() = withCapture("heart") { fixture ->
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        fixture.packets.onFinish = { entered.countDown(); release.await(10, TimeUnit.SECONDS); true }
        try {
            val stop = fixture.controller.onDisconnectRequested()
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            fixture.controller.onSessionError("Injected transport failure")
            release.countDown()
            stop.get(10, TimeUnit.SECONDS)
            val result = requireNotNull(fixture.database.recording(fixture.current.id))
            assertEquals(RecordingStatus.FAILED, result.status)
            assertNotNull(result.captureErrorCode)
        } finally { release.countDown(); fixture.packets.onFinish = null }
    }

    @Test fun staleDirectBeginCannotStopAnActiveRecording() = withCapture("activity") { fixture ->
        val stale = fixture.current.copy(id = UUID.randomUUID().toString())
        try {
            fixture.controller.beginRecordingSession(stale)
            fail("Direct begin must reject an active recording")
        } catch (_: IllegalStateException) { }
        val intent = DeviceFeatureController::class.java.getDeclaredField("terminalIntent").apply { isAccessible = true }
        val request = DeviceFeatureController::class.java.getDeclaredField("finalizationRequest").apply { isAccessible = true }
        synchronized(fixture.controller) {
            assertNull("Rejected begin must not request termination", intent.get(fixture.controller))
            assertNull("Rejected begin must not start finalization", request.get(fixture.controller))
        }
        assertEquals(fixture.current.id, fixture.controller.captureIdentity())
        assertEquals(RecordingStatus.RECORDING, fixture.database.recording(fixture.current.id)?.status)
        assertTrue(fixture.controller.isCaptureActive())
    }

    @Test fun newRecordingIsNotCreatedWhilePreviousStopIsPending() = withCapture("heart") { fixture ->
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        fixture.packets.onFinish = { entered.countDown(); release.await(10, TimeUnit.SECONDS); true }
        try {
            val stop = fixture.controller.onDisconnectRequested()
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            var created = false
            try {
                fixture.controller.createRecordingSession {
                    created = true
                    fixture.database.beginRecording(fixture.dogId, RecordingSource.LIVE, questionnaire("Should not exist", "heart"))
                }
                fail("A second recording must not start during finalization")
            } catch (_: IllegalStateException) { }
            assertFalse("A rejected start created a recording row", created)
            release.countDown()
            stop.get(10, TimeUnit.SECONDS)
            assertEquals(RecordingStatus.COMPLETED, fixture.database.recording(fixture.current.id)?.status)
        } finally { release.countDown(); fixture.packets.onFinish = null }
    }

    @Test fun drainTimeoutKeepsStopPendingUntilRetryFinishes() = withCapture("heart") { fixture ->
        val firstAttempt = CountDownLatch(1)
        val retryEntered = CountDownLatch(1)
        val releaseRetry = CountDownLatch(1)
        val attempts = java.util.concurrent.atomic.AtomicInteger()
        fixture.packets.onFinish = {
            if (attempts.incrementAndGet() == 1) {
                firstAttempt.countDown()
                false
            } else {
                retryEntered.countDown()
                releaseRetry.await(10, TimeUnit.SECONDS)
                true
            }
        }
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            val before = fixture.packets.stopCount.get()
            val stop = fixture.controller.requestDisconnect(executor)
            assertTrue(firstAttempt.await(5, TimeUnit.SECONDS))
            assertTrue("Timed-out drain was not retried", retryEntered.await(5, TimeUnit.SECONDS))
            assertFalse(stop.isDone)
            assertEquals(before, fixture.packets.stopCount.get())
            assertTrue(fixture.controller.isCaptureActive())
            releaseRetry.countDown()
            stop.get(10, TimeUnit.SECONDS)
            assertEquals(before + 1, fixture.packets.stopCount.get())
            assertEquals(RecordingStatus.COMPLETED, fixture.database.recording(fixture.current.id)?.status)
        } finally {
            releaseRetry.countDown()
            fixture.packets.onFinish = null
            executor.shutdownNow()
        }
    }

    @Test fun drainFailureIsReportedWithoutTearingDownOrFinalizing() = withCapture("heart") { fixture ->
        fixture.packets.onFinish = { throw java.io.IOException("Injected packet persistence failure") }
        val before = fixture.packets.stopCount.get()
        try {
            try {
                fixture.controller.onDisconnectRequested().get(10, TimeUnit.SECONDS)
                fail("A failed drain must not report success")
            } catch (error: java.util.concurrent.ExecutionException) {
                assertTrue(error.cause is java.io.IOException)
            }
            assertEquals(before, fixture.packets.stopCount.get())
            assertEquals(RecordingStatus.RECORDING, fixture.database.recording(fixture.current.id)?.status)
            assertTrue(fixture.controller.isCaptureActive())
            assertTrue(File(fixture.database.recordingDirectory(fixture.current.relativeDirectory), "packets.bin").isFile)
        } finally {
            fixture.packets.onFinish = null
            fixture.controller.onDisconnectRequested().get(10, TimeUnit.SECONDS)
        }
    }

    @Test fun notificationStopFailureSignalsServiceForVisibleRetry() = withCapture("heart") { fixture ->
        val previous = CaptureServiceBridge.onStopFailed
        val notified = CountDownLatch(1)
        fixture.packets.onFinish = { throw java.io.IOException("Injected stop failure") }
        CaptureServiceBridge.onStopFailed = { notified.countDown() }
        try {
            DeviceFeatureControllerHolder.requestStop()
            assertTrue("Background stop failure was not reported to the service", notified.await(10, TimeUnit.SECONDS))
            assertTrue(fixture.controller.isCaptureActive())
            assertEquals(RecordingStatus.RECORDING, fixture.database.recording(fixture.current.id)?.status)
        } finally {
            CaptureServiceBridge.onStopFailed = previous
            fixture.packets.onFinish = null
            fixture.controller.onDisconnectRequested().get(10, TimeUnit.SECONDS)
        }
    }

    @Test fun recordingNotificationFailureAfterCommitDoesNotBlockTeardown() = withCapture("activity") { fixture ->
        fixture.controller.setOnRecordingChanged { throw IllegalStateException("Injected notification failure") }
        try {
            fixture.controller.onDisconnectRequested().get(15, TimeUnit.SECONDS)
            assertEquals(RecordingStatus.COMPLETED, fixture.database.recording(fixture.current.id)?.status)
            assertFalse("Committed stop must complete teardown", fixture.controller.shouldRetainConnection())
            assertArrayEquals(byteArrayOf(1, 2, 3), File(fixture.database.recordingDirectory(fixture.current.relativeDirectory), "packets.bin").readBytes())
        } finally { fixture.controller.setOnRecordingChanged {} }
    }

    @Test fun teardownFailureKeepsServiceAndStartGateUntilSuccessfulRetry() = withCapture("heart") { fixture ->
        val stopped = java.util.concurrent.atomic.AtomicBoolean(false)
        fixture.controller.setOnCaptureLifecycleChanged { active -> if (!active) stopped.set(true) }
        fixture.ble.onDisconnect = { throw java.io.IOException("Injected disconnect failure") }
        try {
            try { fixture.controller.onDisconnectRequested().get(10, TimeUnit.SECONDS); fail("Disconnect should fail") }
            catch (_: java.util.concurrent.ExecutionException) { }
            assertEquals(RecordingStatus.COMPLETED, fixture.database.recording(fixture.current.id)?.status)
            assertTrue(fixture.controller.shouldRetainConnection())
            assertFalse("Service was stopped before teardown succeeded", stopped.get())
            var created = false
            try {
                fixture.controller.createRecordingSession {
                    created = true
                    fixture.database.beginRecording(fixture.dogId, RecordingSource.LIVE, questionnaire("Should not exist", "heart"))
                }
                fail("Teardown failure must keep the next capture blocked")
            } catch (_: IllegalStateException) { }
            assertFalse(created)
        } finally {
            fixture.ble.onDisconnect = null
            fixture.controller.onDisconnectRequested().get(10, TimeUnit.SECONDS)
        }
        assertTrue(stopped.get())
        assertFalse(fixture.controller.shouldRetainConnection())
    }

    @Test fun queuedOldBleCallbacksCannotFailTheNextRecording() = withCapture("activity") { fixture ->
        fixture.controller.onDisconnectRequested().get(15, TimeUnit.SECONDS)
        val blocked = CountDownLatch(1)
        val release = CountDownLatch(1)
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            blocked.countDown()
            release.await(15, TimeUnit.SECONDS)
        }
        try {
            assertTrue(blocked.await(5, TimeUnit.SECONDS))
            // Queue callbacks owned by A, then admit B before the UI queue runs.
            fixture.ble.listener.onStateChanged(BleSessionState.FAILED)
            fixture.ble.listener.onError("Old BLE error", null)
            val next = fixture.controller.createRecordingSession {
                fixture.database.beginRecording(fixture.dogId, RecordingSource.LIVE, questionnaire("Next capture", "activity"))
            }
            release.countDown()
            instrumentation.waitForIdleSync()
            val intent = DeviceFeatureController::class.java.getDeclaredField("terminalIntent").apply { isAccessible = true }
            val request = DeviceFeatureController::class.java.getDeclaredField("finalizationRequest").apply { isAccessible = true }
            synchronized(fixture.controller) {
                assertNull("A stale BLE callback staged failure for B", intent.get(fixture.controller))
                assertNull("A stale BLE callback started finalizing B", request.get(fixture.controller))
            }
            assertEquals(RecordingStatus.PREPARING, fixture.database.recording(next.id)?.status)
        } finally { release.countDown() }
    }

    @Test fun nextCaptureStopNeverReusesPreviousPendingOutcome() = withCapture("heart") { fixture ->
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        fixture.controller.setOnRecordingFinalized { recording ->
            if (recording.id == fixture.current.id) { entered.countDown(); release.await(15, TimeUnit.SECONDS) }
        }
        try {
            val first = fixture.controller.onDisconnectRequested()
            assertTrue("Old completion listener did not block", entered.await(10, TimeUnit.SECONDS))
            assertFalse(first.isDone)
            val next = fixture.controller.createRecordingSession {
                fixture.database.beginRecording(fixture.dogId, RecordingSource.LIVE, questionnaire("Next capture", "activity"))
            }
            val second = fixture.controller.onDisconnectRequested()
            assertNotSame("Next stop must not reuse the preceding outcome", first, second)
            assertFalse(second.isDone)
            release.countDown()
            first.get(10, TimeUnit.SECONDS)
            second.get(10, TimeUnit.SECONDS)
            assertEquals(RecordingStatus.COMPLETED, fixture.database.recording(next.id)?.status)
        } finally { release.countDown() }
    }

    @Test fun failedRecoveryCanBeRetriedWithoutDroppingPendingStop() = withCapture("heart") { fixture ->
        val previous = CaptureServiceBridge.onStopFailed
        val notified = CountDownLatch(1)
        val attempts = java.util.concurrent.atomic.AtomicInteger()
        fixture.packets.onFinish = { throw java.io.IOException("Injected packet failure") }
        fixture.packets.onRecover = { directory ->
            if (attempts.getAndIncrement() == 0) PacketRecoveryResult.Failed
            else PacketRecoveryResult.Recovered(File(directory, "packet-recovery-${UUID.randomUUID()}.bin").apply { writeBytes(byteArrayOf(1, 2, 3)) })
        }
        CaptureServiceBridge.onStopFailed = { notified.countDown() }
        try {
            val pending = fixture.controller.onDisconnectRequested()
            assertTrue(notified.await(10, TimeUnit.SECONDS))
            assertFalse(pending.isDone)
            assertEquals(RecordingStatus.RECORDING, fixture.database.recording(fixture.current.id)?.status)
            assertSame(pending, fixture.controller.onDisconnectRequested())
            pending.get(10, TimeUnit.SECONDS)
            assertEquals(RecordingStatus.FAILED, fixture.database.recording(fixture.current.id)?.status)
            assertTrue(attempts.get() >= 2)
        } finally {
            CaptureServiceBridge.onStopFailed = previous
            fixture.packets.onFinish = null
            fixture.packets.onRecover = null
        }
    }

    @Test fun recoveredPacketErrorSurvivesDatabaseFailureEvenIfNextDrainSucceeds() = withCapture("activity") { fixture ->
        val attempts = java.util.concurrent.atomic.AtomicInteger()
        val trigger = "reject_packet_error_${UUID.randomUUID().toString().replace("-", "")}"
        val db = fixture.database.writableDatabase
        val bytes = byteArrayOf(87, 80, 82, 69, 67, 79, 86, 0, 1, 2)
        db.execSQL("CREATE TRIGGER $trigger BEFORE UPDATE OF capture_error_code ON recordings BEGIN SELECT RAISE(ABORT,'synthetic error persistence failure'); END")
        fixture.packets.onFinish = { if (attempts.getAndIncrement() == 0) throw java.io.IOException("Injected packet failure") else true }
        fixture.packets.onRecover = { directory ->
            PacketRecoveryResult.Recovered(File(directory, "packet-recovery-${UUID.randomUUID()}.bin").apply { writeBytes(bytes) })
        }
        try {
            try { fixture.controller.onDisconnectRequested().get(15, TimeUnit.SECONDS); fail("Error code persistence must succeed before commit") }
            catch (_: java.util.concurrent.ExecutionException) { }
            assertEquals(RecordingStatus.RECORDING, fixture.database.recording(fixture.current.id)?.status)
            db.execSQL("DROP TRIGGER $trigger")
            fixture.controller.onDisconnectRequested().get(15, TimeUnit.SECONDS)
            val recording = requireNotNull(fixture.database.recording(fixture.current.id))
            assertEquals(RecordingStatus.FAILED, recording.status)
            assertEquals("packet_persistence_failed", recording.captureErrorCode)
            assertArrayEquals(bytes, fixture.database.resolveRelativePath(recording.artifacts.single { it.type == ArtifactType.IMPORTED_SOURCE }.relativePath).readBytes())
        } finally {
            fixture.packets.onFinish = null
            fixture.packets.onRecover = null
            db.execSQL("DROP TRIGGER IF EXISTS $trigger")
        }
    }

    @Test fun packetAndPolarFailuresPreserveBothDetailsWithPacketPriority() {
        withCapture("activity", polarStoreFactory = {
            com.example.myapplication.storage.PolarCsvFileStore { file ->
                val output = java.io.FileOutputStream(file, true)
                object : java.io.OutputStream() {
                    override fun write(value: Int) = output.write(value)
                    override fun write(bytes: ByteArray, offset: Int, length: Int) {
                        if (file.name == "polar_hr.csv") throw java.io.IOException("Injected Polar failure")
                        output.write(bytes, offset, length)
                    }
                    override fun close() = output.close()
                }
            }
        }) { fixture ->
            fixture.packets.onFinish = { throw java.io.IOException("Injected packet failure") }
            fixture.packets.onRecover = { directory ->
                PacketRecoveryResult.Recovered(File(directory, "packet-recovery-${UUID.randomUUID()}.bin").apply { writeBytes(byteArrayOf(1, 2, 3)) })
            }
            try {
                instrumentation.runOnMainSync { fixture.controller.onPolarStatusChanged(PolarStatus(state = PolarConnectionState.READY)) }
                fixture.controller.onPolarHeartRate(com.example.myapplication.protocol.PolarHeartRateFrame(72, listOf(800)), 1_000L)
                fixture.controller.onDisconnectRequested().get(15, TimeUnit.SECONDS)
                val recording = requireNotNull(fixture.database.recording(fixture.current.id))
                assertEquals(RecordingStatus.FAILED, recording.status)
                assertEquals("packet_persistence_failed", recording.captureErrorCode)
                assertTrue(requireNotNull(recording.captureErrorMessage).contains("Polar also failed"))
                assertArrayEquals(byteArrayOf(1, 2, 3), File(fixture.database.recordingDirectory(recording.relativeDirectory), "packets.bin").readBytes())
            } finally { fixture.packets.onFinish = null; fixture.packets.onRecover = null }
        }
    }

    @Test fun recoveredPacketFailureFinalizesAsFailedAndRegistersRecoveryArtifact() = withCapture("heart") { fixture ->
        val bytes = byteArrayOf(87, 80, 82, 69, 67, 79, 86, 0, 1, 2)
        fixture.packets.onFinish = { throw java.io.IOException("Injected packet failure") }
        fixture.packets.onRecover = { directory ->
            val file = File(directory, "packet-recovery-${UUID.randomUUID()}.bin").apply { writeBytes(bytes) }
            PacketRecoveryResult.Recovered(file)
        }
        try {
            fixture.controller.onDisconnectRequested().get(10, TimeUnit.SECONDS)
            val recording = requireNotNull(fixture.database.recording(fixture.current.id))
            assertEquals(RecordingStatus.FAILED, recording.status)
            assertEquals("packet_persistence_failed", recording.captureErrorCode)
            val recovery = recording.artifacts.single { it.type == ArtifactType.IMPORTED_SOURCE }
            val file = fixture.database.resolveRelativePath(recovery.relativePath)
            assertArrayEquals(bytes, file.readBytes())
            var created = false
            try {
                fixture.controller.createRecordingSession {
                    created = true
                    fixture.database.beginRecording(fixture.dogId, RecordingSource.LIVE, questionnaire("Should not exist", "heart"))
                }
                fail("A failed packet processor must not be reused")
            } catch (_: IllegalStateException) { }
            assertFalse(created)
        } finally { fixture.packets.onFinish = null; fixture.packets.onRecover = null }
    }

    @Test fun promptIntentWriteFailurePreventsTerminalCommitAndCanBeRetried() = withCapture("heart") { fixture ->
        fixture.controller.setOnRecordingFinalizing { throw java.io.IOException("Injected intent failure") }
        try {
            try {
                fixture.controller.onDisconnectRequested().get(10, TimeUnit.SECONDS)
                fail("Finalization must not succeed without the pending intent")
            } catch (error: java.util.concurrent.ExecutionException) {
                assertTrue(error.cause is java.io.IOException)
            }
            assertEquals(RecordingStatus.RECORDING, fixture.database.recording(fixture.current.id)?.status)
            assertTrue(fixture.controller.isCaptureActive())
            assertTrue(File(fixture.database.recordingDirectory(fixture.current.relativeDirectory), "packets.bin").isFile)
        } finally {
            fixture.controller.setOnRecordingFinalizing { }
            fixture.controller.onDisconnectRequested().get(10, TimeUnit.SECONDS)
        }
    }

    @Test fun retryingUnrelatedDeletionDoesNotBlockNewFinalizationCleanup() = withCapture("activity") { fixture ->
        val manager = androidx.work.WorkManager.getInstance(context)
        val name = "local-retirement-cleanup"
        val outboxId = UUID.randomUUID().toString()
        val marker = java.security.MessageDigest.getInstance("SHA-256").digest(fixture.current.id.toByteArray())
            .joinToString("") { "%02x".format(it) }
        manager.cancelUniqueWork(name).result.get(10, TimeUnit.SECONDS)
        val db = fixture.database.writableDatabase
        db.execSQL("INSERT INTO local_deletion_outbox(id,relative_path,entry_kind,created_at_utc) VALUES(?,?,?,?)",
            arrayOf(outboxId, "../unremovable-$outboxId", "file", "2026-01-01T00:00:00Z"))
        try {
            ActivityScenario.launch(MainActivity::class.java).use {
                awaitRecordingHistory()
                com.example.myapplication.sync.LocalRetirementCleanupWorker.enqueue(context)
                compose.waitUntil(30_000) {
                    manager.getWorkInfosForUniqueWork(name).get(2, TimeUnit.SECONDS)
                        .any { it.state == androidx.work.WorkInfo.State.ENQUEUED && it.runAttemptCount >= 1 }
                }
                db.execSQL("INSERT INTO deferred_retirements(kind,id_sha256,received_at_utc) VALUES('recording',?,?)", arrayOf(marker, "2026-01-01T00:00:00Z"))
                stopSession()
                // The old retry has a 30-second backoff. The newly finalized
                // recording must not be appended behind that retry chain.
                compose.waitUntil(15_000) { fixture.database.recording(fixture.current.id) == null }
                assertEquals(1, db.rawQuery("SELECT COUNT(*) FROM local_deletion_outbox WHERE id=?", arrayOf(outboxId)).use { it.moveToFirst(); it.getInt(0) })
            }
        } finally {
            manager.cancelUniqueWork(name).result.get(10, TimeUnit.SECONDS)
            db.delete("local_deletion_outbox", "id=?", arrayOf(outboxId))
            db.delete("deferred_retirements", "id_sha256=?", arrayOf(marker))
        }
    }

    @Test fun actualSqliteWriterContentionKeepsFailureAndOriginalUntilStopCompletes() = withCapture("activity") { fixture ->
        val reachedDrain = CountDownLatch(1)
        fixture.packets.onFinish = { reachedDrain.countDown(); true }
        val other = android.database.sqlite.SQLiteDatabase.openDatabase(
            fixture.database.writableDatabase.path, null, android.database.sqlite.SQLiteDatabase.OPEN_READWRITE,
        )
        lateinit var stop: java.util.concurrent.CompletableFuture<Unit>
        try {
            other.beginTransaction()
            try {
                // An independent SQLite connection owns a real write lock.
                // Roll back this no-op update after testing, preserving the row.
                other.execSQL("UPDATE recordings SET status=status WHERE id=?", arrayOf(fixture.current.id))
                fixture.controller.onSessionError("Synthetic failure under SQLite contention", null)
                stop = fixture.controller.onDisconnectRequested()
                assertTrue("Finalization did not reach packet drain", reachedDrain.await(10, TimeUnit.SECONDS))
                Thread.sleep(1_000)
                assertFalse("Stop cannot commit while another writer owns the database", stop.isDone)
                assertArrayEquals(byteArrayOf(1, 2, 3), File(fixture.database.recordingDirectory(fixture.current.relativeDirectory), "packets.bin").readBytes())
            } finally { other.endTransaction() }
            stop.get(60, TimeUnit.SECONDS)
            val result = requireNotNull(fixture.database.recording(fixture.current.id))
            assertEquals(RecordingStatus.FAILED, result.status)
            assertEquals("capture_error", result.captureErrorCode)
            assertArrayEquals(byteArrayOf(1, 2, 3), File(fixture.database.recordingDirectory(fixture.current.relativeDirectory), "packets.bin").readBytes())
        } finally { other.close() }
    }

    @Test fun lockedPostStopCleanupIsRetriedLocallyWithoutDeletingOriginal() {
        val finalized = CountDownLatch(1)
        val proceed = CountDownLatch(1)
        withCapture("heart") { fixture ->
            val marker = UUID.randomUUID().toString().replace("-", "").repeat(2)
            val manager = androidx.work.WorkManager.getInstance(context)
            val name = "local-retirement-cleanup"
            val appDb = ActivityDatabase.get(context).writableDatabase
            val oldTimeout = appDb.rawQuery("PRAGMA busy_timeout", null).use { it.moveToFirst(); it.getInt(0) }
            appDb.rawQuery("PRAGMA busy_timeout=100", null).use { it.moveToFirst() }
            manager.cancelUniqueWork(name).result.get(10, TimeUnit.SECONDS)
            try {
                ActivityScenario.launch(MainActivity::class.java).use {
                    awaitRecordingHistory()
                    fixture.controller.setOnCaptureLifecycleChanged { active ->
                        if (!active) {
                            CaptureForegroundService.stop(context)
                            finalized.countDown()
                            proceed.await(20, TimeUnit.SECONDS)
                        }
                    }
                    fixture.database.writableDatabase.execSQL("INSERT INTO deferred_retirements(kind,id_sha256,received_at_utc) VALUES('recording',?,?)", arrayOf(marker, "2026-01-01T00:00:00Z"))
                    stopSession()
                    assertTrue("Capture did not finish", finalized.await(15, TimeUnit.SECONDS))
                    val otherConnection = fixture.database.writableDatabase
                    var retryId: UUID? = null
                    otherConnection.beginTransaction()
                    try {
                        proceed.countDown()
                        // Android's connection pool can use its own busy timeout
                        // even when one connection's PRAGMA was shortened.
                        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(45)
                        while (retryId == null && System.nanoTime() < deadline) {
                            retryId = manager.getWorkInfosForUniqueWork(name).get(2, TimeUnit.SECONDS)
                                .firstOrNull { it.state == androidx.work.WorkInfo.State.ENQUEUED && it.runAttemptCount >= 1 }?.id
                            if (retryId == null) Thread.sleep(100)
                        }
                        assertNotNull("Local cleanup never reported a lock retry", retryId)
                        assertEquals(1, otherConnection.rawQuery("SELECT COUNT(*) FROM deferred_retirements WHERE id_sha256=?", arrayOf(marker)).use { it.moveToFirst(); it.getInt(0) })
                        assertTrue(File(fixture.database.recordingDirectory(fixture.current.relativeDirectory), "packets.bin").isFile)
                    } finally { otherConnection.endTransaction() }
                    val id = requireNotNull(retryId)
                    compose.waitUntil(60_000) { manager.getWorkInfoById(id).get(2, TimeUnit.SECONDS)?.state == androidx.work.WorkInfo.State.SUCCEEDED }
                    assertEquals(0, fixture.database.readableDatabase.rawQuery("SELECT COUNT(*) FROM deferred_retirements WHERE id_sha256=?", arrayOf(marker)).use { it.moveToFirst(); it.getInt(0) })
                    assertEquals(RecordingStatus.COMPLETED, fixture.database.recording(fixture.current.id)?.status)
                    assertTrue(File(fixture.database.recordingDirectory(fixture.current.relativeDirectory), "packets.bin").isFile)
                }
            } finally {
                proceed.countDown()
                manager.cancelUniqueWork(name).result.get(10, TimeUnit.SECONDS)
                appDb.rawQuery("PRAGMA busy_timeout=$oldTimeout", null).use { it.moveToFirst() }
                fixture.database.writableDatabase.delete("deferred_retirements", "id_sha256=?", arrayOf(marker))
            }
        }
    }

    private fun hasNode(matcher: SemanticsMatcher): Boolean = try {
        compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty()
    } catch (error: IllegalStateException) {
        if (error.message?.startsWith("No compose hierarchies found") == true) false else throw error
    }

    private fun awaitReady()=compose.waitUntil(15_000) {hasNode(hasTestTag("tab.animals"))}
    private fun awaitRecordingHistory() {
        awaitReady()
        compose.onNodeWithTag("tab.recordings").performClick()
        compose.waitUntil(10_000) {hasNode(hasText("Capture: recording", substring = true))}
    }
    private fun stopSession() {
        compose.onNodeWithTag("tab.session").performClick()
        compose.onNode(hasScrollAction()).performScrollToNode(hasText("Stop session"))
        compose.onNodeWithText("Stop session").performClick()
    }
    private fun awaitHeartEditor()=compose.waitUntil(10_000) {hasNode(hasText("Activity and heart questionnaire"))}

    private fun withCapture(kind:String, startCapture:Boolean = true, packetBytes: ByteArray = byteArrayOf(1, 2, 3), polarStoreFactory: () -> com.example.myapplication.storage.PolarCsvFileStore = { com.example.myapplication.storage.PolarCsvFileStore() }, body:(Fixture)->Unit) {
        val server=context.getSharedPreferences("woona_server",Context.MODE_PRIVATE)
        val oldAccount=server.getString("account_id",null)
        val hadDisconnected=server.contains("explicitly_disconnected")
        val oldDisconnected=server.getBoolean("explicitly_disconnected",false)
        val profiles=context.getSharedPreferences("woona_profiles",Context.MODE_PRIVATE)
        val oldSelected=profiles.getString("last_profile_id",null)
        val language=AppLanguagePreferences(context);val oldLanguage=language.selectedLanguage()
        server.edit().remove("account_id").putBoolean("explicitly_disconnected",true).commit()
        language.setSelectedLanguage(AppLanguage.ENGLISH)
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName,Manifest.permission.BLUETOOTH_CONNECT)
        val database=WoonaDatabase(context)
        val dog=database.saveProfile(DogQuestionnaire(schemaVersion=2,animalId="heart-prompt-${UUID.randomUUID()}",numberOrName="Synthetic heart prompt"))
        profiles.edit().putString("last_profile_id",dog.id).commit()
        val old=database.beginRecording(dog.id,RecordingSource.LIVE,questionnaire("Old unfilled heart","heart"))
        database.finishRecording(old.id,RecordingStatus.COMPLETED)
        val current=database.beginRecording(dog.id,RecordingSource.LIVE,questionnaire("Changed capture",kind))
        lateinit var ble:PromptBle
        val packets = PromptPackets(packetBytes)
        val controller=createDeviceFeatureController(context,context.filesDir,"${context.packageName}.provider",UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),
            packetCaptureControllerFactory={_,_->packets},bleSessionControllerFactory={listener->PromptBle(listener).also {ble=it}},woonaDatabase=database,
            onCaptureLifecycleChanged={active->if(!active)CaptureForegroundService.stop(context)},polarFileStoreFactory=polarStoreFactory)
        val fixture=Fixture(database,dog.id,old,current,controller,packets,ble)
        try {
            instrumentation.runOnMainSync {
                controller.beginRecordingSession(current)
                assertSame(controller,DeviceFeatureControllerHolder.obtain({}) {controller})
                controller.onConnectRequested("00:11:22:33:44:55")
                ble.listener.onStateChanged(BleSessionState.CONNECTED)
                ble.listener.onCaptureReady()
            }
            instrumentation.waitForIdleSync()
            if (startCapture) {
                instrumentation.runOnMainSync {controller.startSynchronizedSession()}
                assertEquals(RecordingStatus.RECORDING,database.recording(current.id)?.status)
            } else {
                assertEquals(RecordingStatus.PREPARING,database.recording(current.id)?.status)
            }
            body(fixture)
        } finally {
            instrumentation.runOnMainSync { controller.onDisconnectRequested() }
            compose.waitUntil(15_000) { !controller.shouldRetainConnection() }
            instrumentation.runOnMainSync { DeviceFeatureControllerHolder.releaseIfInactive(controller) }
            CaptureForegroundService.stop(context)
            database.writableDatabase.delete("recordings","dog_id=?",arrayOf(dog.id))
            database.writableDatabase.delete("dog_profile_versions","dog_id=?",arrayOf(dog.id))
            database.writableDatabase.delete("dogs","id=?",arrayOf(dog.id))
            File(database.rootDirectory,"recordings/${dog.id}").deleteRecursively()
            PendingHeartPrompts(context).remove(current.id)
            database.close()
            val edit=server.edit().putString("account_id",oldAccount)
            if(hadDisconnected)edit.putBoolean("explicitly_disconnected",oldDisconnected) else edit.remove("explicitly_disconnected")
            edit.commit();profiles.edit().putString("last_profile_id",oldSelected).commit();language.setSelectedLanguage(oldLanguage)
        }
    }
    private inner class Fixture(val database:WoonaDatabase,val dogId:String,val old:Recording,val current:Recording,val controller:DeviceFeatureController,val packets:PromptPackets,val ble:PromptBle) {
        fun completedHeart(label:String) {val r=database.beginRecording(dogId,RecordingSource.LIVE,questionnaire(label,"heart"));database.finishRecording(r.id,RecordingStatus.COMPLETED)}
    }
    private fun questionnaire(label:String,kind:String)=SessionQuestionnaire(schemaVersion=2,sessionLabel=label,sessionKind=kind,plannedActivities=if(kind=="heart")emptyList() else listOf("Покой"),videoRequested=false)
    private class PromptPackets(private val packetBytes: ByteArray):PacketCaptureController {
        private var packet:File?=null
        val stopCount = java.util.concurrent.atomic.AtomicInteger()
        val dropped = java.util.concurrent.atomic.AtomicLong()
        @Volatile var onFinish: (() -> Boolean)? = null
        @Volatile var onRecover: ((File) -> PacketRecoveryResult)? = null
        override fun recoverPendingFragments(directory: File) = onRecover?.invoke(directory) ?: PacketRecoveryResult.Unsupported
        override fun useSessionDirectory(directory:File) { dropped.set(0); packet=File(directory,"packets.bin").apply {writeBytes(packetBytes)}}
        override fun droppedFragments() = dropped.get()
        override fun submit(packetFragment:ByteArray)=PacketSubmitResult.ACCEPTED
        override fun recordDiagnosticEvent(type:PacketDiagnosticType,message:String) {}
        override fun stopCapture() { stopCount.incrementAndGet() }
        override fun finishCapture(timeoutMillis: Long) = onFinish?.invoke() ?: true
        override fun updateSelection(sensorType:Int,channel:Int) {}
        override fun resetSession() {};override fun flush() {};override fun currentFile()=packet;override fun close() {}
    }
    private class PromptBle(val listener:BleSessionListener):BleSessionController {
        @Volatile var onDisconnect: (() -> Unit)? = null
        override fun currentState()=BleSessionState.CONNECTED
        override fun currentTransportProfile()=BleTransportProfile.COMPATIBILITY
        override fun updateTransportProfile(profile:BleTransportProfile) {};override fun startScanning() {};override fun stopScanning() {}
        override fun connect(address:String) {};override fun disconnect() { onDisconnect?.invoke() };override fun close() {}
    }
}
