package com.example.myapplication.sync

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.*
import com.example.myapplication.data.*
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ServerDisconnectDeviceTest {
    @Test fun freshWifiPolicyIsUnmeteredButAnExistingMeteredPreferenceIsPreserved() {
        val context=ApplicationProvider.getApplicationContext<Context>()
        val prefs=context.getSharedPreferences("woona_server",Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        val store=ServerSettingsStore(context)
        assertTrue(store.get().wifiOnly)
        prefs.edit().putBoolean("wifi_only",false).commit()
        assertFalse(ServerSettingsStore(context).get().wifiOnly)
        prefs.edit().clear().commit()
    }
    @Test fun disconnectInterruptsAnActiveHttpReadAndRejectsTheOldClientSnapshot() {
        val context=ApplicationProvider.getApplicationContext<Context>()
        val prefs=context.getSharedPreferences("woona_server",Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        val accepted=java.util.concurrent.CountDownLatch(1)
        val release=java.util.concurrent.CountDownLatch(1)
        java.net.ServerSocket(0,1,java.net.InetAddress.getLoopbackAddress()).use { server ->
            val responder=Thread {
                server.accept().use { socket ->
                    val input=socket.getInputStream();val header=java.io.ByteArrayOutputStream()
                    while(!header.toString("UTF-8").endsWith("\r\n\r\n")) {val byte=input.read();if(byte<0)break;header.write(byte)}
                    socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100000\r\n\r\n{".toByteArray())
                    socket.getOutputStream().flush();accepted.countDown();release.await(8,TimeUnit.SECONDS)
                }
            }.apply {isDaemon=true;start()}
            val store=ServerSettingsStore(context)
            store.save("http://127.0.0.1:${server.localPort}","synthetic-read-cancel",true)
            val old=store.get()
            val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
            val result=pool.submit<Throwable?> {try {ServerApiClient(old).fetchDeletions();null} catch(error:Throwable) {error}}
            try {
                assertTrue(accepted.await(5,TimeUnit.SECONDS))
                ServerSyncScheduler.disconnect(context)
                assertNotNull(result.get(3,TimeUnit.SECONDS))
                assertFalse(store.get().isConfigured)
                assertThrows(java.util.concurrent.CancellationException::class.java) {ServerApiClient(old).fetchDeletions()}
            } finally {release.countDown();pool.shutdownNow();responder.join(2000);prefs.edit().clear().commit()}
        }
    }

    @Test fun disconnectCancelsQueuedWorkersAndPreservesEveryRecordingByteOffsetReceiptAndAccount() {
        val context=ApplicationProvider.getApplicationContext<Context>()
        val prefs=context.getSharedPreferences("woona_server",Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        val store=ServerSettingsStore(context)
        store.save("https://invalid.example","synthetic-disconnect-token",false);store.setAccount("qa-disconnect")
        val manager=WorkManager.getInstance(context)
        val root=File(context.filesDir,"Woona")
        val database=WoonaDatabase(context)
        val dog=database.saveProfile(DogQuestionnaire(schemaVersion=2,animalId="disconnect-${UUID.randomUUID()}",numberOrName="Disconnect"),accountId="qa-disconnect")
        val record=database.beginRecording(dog.id,RecordingSource.LIVE,SessionQuestionnaire(schemaVersion=2,sessionLabel="Keep source",plannedActivities=listOf("walk"),videoRequested=false))
        val file=File(database.recordingDirectory(record.relativeDirectory),"packets.bin").apply {writeText("preserved original bytes")}
        database.writeSyncMetadata(record.id,CaptureSyncMetadata(recordingId=record.id,profileId=dog.id,source="live",timezone=record.timezone,selectedSessionStartUtc=record.startedAtUtc))
        database.finishRecording(record.id,RecordingStatus.COMPLETED)
        val packet=requireNotNull(database.recordingSyncRecord(record.id)).artifacts.first {it.type=="packet"}
        database.markArtifactProgress(packet.id,5)
        database.markRecordingUploading(record.id)
        database.writableDatabase.execSQL("UPDATE server_sync_state SET server_receipt_sha256=? WHERE recording_id=?",arrayOf("b".repeat(64),record.id))
        val before=requireNotNull(database.recordingSyncRecord(record.id)).artifacts
        val name="server-sync-${record.id}"
        val request=OneTimeWorkRequestBuilder<RecordingSyncWorker>().setInputData(workDataOf("id" to record.id)).addTag(ServerSyncScheduler.WORK_TAG).setInitialDelay(1,TimeUnit.DAYS).build()
        manager.enqueueUniqueWork(name,ExistingWorkPolicy.KEEP,request).result.get(10,TimeUnit.SECONDS)
        try {
            ServerSyncScheduler.disconnect(context)
            val settings=store.get()
            assertFalse(settings.isConfigured);assertEquals("",settings.token)
            assertEquals("https://invalid.example",settings.baseUrl);assertEquals("qa-disconnect",settings.accountId);assertFalse(settings.wifiOnly)
            assertEquals(WorkInfo.State.CANCELLED,manager.getWorkInfosForUniqueWork(name).get().first {it.id==request.id}.state)
            assertEquals("preserved original bytes",file.readText())
            assertEquals(before,requireNotNull(database.recordingSyncRecord(record.id)).artifacts)
            assertEquals("b".repeat(64),database.recording(record.id)?.serverReceiptSha256)
            assertTrue(database.recording(record.id)?.serverSyncState!="uploading")
            assertTrue(database.pendingRecordingIds().contains(record.id))
            store.save("https://invalid.example","synthetic-reconnected-token",false)
            assertTrue(store.get().isConfigured)
        } finally {
            manager.cancelUniqueWork(name).result.get(10,TimeUnit.SECONDS)
            store.clearToken();prefs.edit().clear().commit()
            database.close()
        }
    }
}
