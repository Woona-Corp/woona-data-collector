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

    private fun awaitReady()=compose.waitUntil(15_000) {compose.onAllNodesWithTag("tab.animals").fetchSemanticsNodes().isNotEmpty()}
    private fun awaitRecordingHistory() {
        awaitReady()
        compose.onNodeWithTag("tab.recordings").performClick()
        compose.waitUntil(10_000) {compose.onAllNodesWithText("Capture: recording",substring=true).fetchSemanticsNodes().isNotEmpty()}
    }
    private fun stopSession() {
        compose.onNodeWithTag("tab.session").performClick()
        compose.onNode(hasScrollAction()).performScrollToNode(hasText("Stop session"))
        compose.onNodeWithText("Stop session").performClick()
    }
    private fun awaitHeartEditor()=compose.waitUntil(10_000) {compose.onAllNodesWithText("Activity and heart questionnaire").fetchSemanticsNodes().isNotEmpty()}

    private fun withCapture(kind:String,body:(Fixture)->Unit) {
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
        val controller=createDeviceFeatureController(context,context.filesDir,"${context.packageName}.provider",UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),
            packetCaptureControllerFactory={_,_->PromptPackets()},bleSessionControllerFactory={listener->PromptBle(listener).also {ble=it}},woonaDatabase=database,
            onCaptureLifecycleChanged={active->if(!active)CaptureForegroundService.stop(context)})
        val fixture=Fixture(database,dog.id,old,current,controller)
        try {
            instrumentation.runOnMainSync {
                controller.beginRecordingSession(current)
                assertSame(controller,DeviceFeatureControllerHolder.obtain({}) {controller})
                controller.onConnectRequested("00:11:22:33:44:55")
                ble.listener.onStateChanged(BleSessionState.CONNECTED)
                ble.listener.onCaptureReady()
            }
            instrumentation.waitForIdleSync()
            instrumentation.runOnMainSync {controller.startSynchronizedSession()}
            assertEquals(RecordingStatus.RECORDING,database.recording(current.id)?.status)
            body(fixture)
        } finally {
            instrumentation.runOnMainSync {controller.onDisconnectRequested();DeviceFeatureControllerHolder.releaseIfInactive(controller)}
            CaptureForegroundService.stop(context)
            database.writableDatabase.delete("recordings","dog_id=?",arrayOf(dog.id))
            database.writableDatabase.delete("dog_profile_versions","dog_id=?",arrayOf(dog.id))
            database.writableDatabase.delete("dogs","id=?",arrayOf(dog.id))
            File(database.rootDirectory,"recordings/${dog.id}").deleteRecursively()
            database.close()
            val edit=server.edit().putString("account_id",oldAccount)
            if(hadDisconnected)edit.putBoolean("explicitly_disconnected",oldDisconnected) else edit.remove("explicitly_disconnected")
            edit.commit();profiles.edit().putString("last_profile_id",oldSelected).commit();language.setSelectedLanguage(oldLanguage)
        }
    }
    private inner class Fixture(val database:WoonaDatabase,val dogId:String,val old:Recording,val current:Recording,val controller:DeviceFeatureController) {
        fun completedHeart(label:String) {val r=database.beginRecording(dogId,RecordingSource.LIVE,questionnaire(label,"heart"));database.finishRecording(r.id,RecordingStatus.COMPLETED)}
    }
    private fun questionnaire(label:String,kind:String)=SessionQuestionnaire(schemaVersion=2,sessionLabel=label,sessionKind=kind,plannedActivities=if(kind=="heart")emptyList() else listOf("Покой"),videoRequested=false)
    private class PromptPackets:PacketCaptureController {
        private var packet:File?=null
        override fun useSessionDirectory(directory:File) {packet=File(directory,"packets.bin").apply {writeBytes(byteArrayOf(1,2,3))}}
        override fun submit(packetFragment:ByteArray)=PacketSubmitResult.ACCEPTED
        override fun recordDiagnosticEvent(type:PacketDiagnosticType,message:String) {}
        override fun stopCapture() {};override fun updateSelection(sensorType:Int,channel:Int) {}
        override fun resetSession() {};override fun flush() {};override fun currentFile()=packet;override fun close() {}
    }
    private class PromptBle(val listener:BleSessionListener):BleSessionController {
        override fun currentState()=BleSessionState.CONNECTED
        override fun currentTransportProfile()=BleTransportProfile.COMPATIBILITY
        override fun updateTransportProfile(profile:BleTransportProfile) {};override fun startScanning() {};override fun stopScanning() {}
        override fun connect(address:String) {};override fun disconnect() {};override fun close() {}
    }
}
