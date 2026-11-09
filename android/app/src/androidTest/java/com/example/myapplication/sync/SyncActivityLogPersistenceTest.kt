package com.example.myapplication.sync

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class SyncActivityLogPersistenceTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val id = UUID.randomUUID().toString()
    private val prefs get() = context.getSharedPreferences(SyncActivityLog.PREFS, Context.MODE_PRIVATE)

    @Before fun clear() { assertTrue(prefs.edit().clear().commit()) }
    @After fun clean() { prefs.edit().clear().commit() }

    private fun awaitCount(count: Int): List<SyncActivityEvent> {
        val deadline = System.nanoTime() + 5_000_000_000L
        while (System.nanoTime() < deadline) {
            val events = SyncActivityLog.recent(context, "recording", id, 128)
            if (events.size == count) return events
            Thread.sleep(10)
        }
        fail("Journal did not reach $count actual events")
        return emptyList()
    }

    private fun row(action: String = "upload"): JSONObject = JSONObject().apply {
        put("timestampUtc", "2026-11-07T12:00:00Z"); put("entityKind", "recording")
        put("entityId", id); put("action", action); put("outcome", "started")
    }

    @Test fun actualEventsPersistAndUnsafeDiagnosticNeverReachesPreferences() {
        assertTrue(SyncActivityLog.recent(context, "recording", id).isEmpty())
        SyncActivityLog.record(context, "recording", id, SyncActivityAction.UPLOAD,
            SyncActivityOutcome.STARTED, "Bearer synthetic-private-token")
        val started = awaitCount(1).single()
        assertNull(started.code)
        SyncActivityLog.record(context, "recording", id, SyncActivityAction.UPLOAD,
            SyncActivityOutcome.SUCCEEDED)
        val events = awaitCount(2)
        assertEquals(listOf("succeeded", "started"), events.map { it.outcome })
        assertEquals(started.timestampUtc, events.last().timestampUtc)
        val stored = prefs.getString(SyncActivityLog.KEY, null)!!
        assertFalse(stored.contains("synthetic-private-token"))
        // Reopen preferences via a separate Context and decode persisted bytes.
        val reopened = context.createPackageContext(context.packageName, 0)
            .getSharedPreferences(SyncActivityLog.PREFS, Context.MODE_PRIVATE)
        assertEquals(events.reversed(), SyncActivityLog.decode(reopened.getString(SyncActivityLog.KEY, null)))
    }

    @Test fun corruptedAndOversizedStorageDoesNotBreakActualLogging() {
        for (corrupted in listOf("not json", "[", "x".repeat(SyncActivityLog.MAX_JSON_CHARS + 1))) {
            prefs.edit().putString(SyncActivityLog.KEY, corrupted).commit()
            assertTrue(SyncActivityLog.recent(context, "recording", id).isEmpty())
            SyncActivityLog.record(context, "recording", id, SyncActivityAction.LOCAL_SAVED,
                SyncActivityOutcome.SUCCEEDED)
            assertEquals("local_saved", awaitCount(1).single().action)
        }
    }

    @Test fun wrongPreferenceTypeDoesNotPoisonFutureAppends() {
        prefs.edit().putInt(SyncActivityLog.KEY, 7).commit()
        assertTrue(SyncActivityLog.recent(context, "recording", id).isEmpty())
        SyncActivityLog.record(context, "recording", id, SyncActivityAction.UPLOAD,
            SyncActivityOutcome.SUCCEEDED)
        assertEquals("succeeded", awaitCount(1).single().outcome)
    }

    @Test fun malformedRowsAreIgnoredSafeRowsPreservedAndCapEnforcedOnAppend() {
        val rows = JSONArray().put(row()).put("bad row").put(row("raw JSON/token"))
            .put(row().put("code", "Bearer synthetic-secret"))
        prefs.edit().putString(SyncActivityLog.KEY, rows.toString()).commit()
        val safe = SyncActivityLog.recent(context, "recording", id)
        assertEquals(2, safe.size)
        assertTrue(safe.all { it.code == null })
        val full = JSONArray()
        repeat(128) { full.put(row()) }
        prefs.edit().putString(SyncActivityLog.KEY, full.toString()).commit()
        SyncActivityLog.record(context, "recording", id, SyncActivityAction.UPLOAD,
            SyncActivityOutcome.SUCCEEDED, "http_409")
        val deadline = System.nanoTime() + 5_000_000_000L
        while (System.nanoTime() < deadline &&
            SyncActivityLog.recent(context, "recording", id).first().outcome != "succeeded") Thread.sleep(10)
        val recent = SyncActivityLog.recent(context, "recording", id, 999)
        assertEquals(128, recent.size)
        assertEquals("succeeded", recent.first().outcome)
        assertEquals("http_409", recent.first().code)
        assertTrue(prefs.getString(SyncActivityLog.KEY, "")!!.length <= SyncActivityLog.MAX_JSON_CHARS)
    }

    @Test fun concurrentAppendsDoNotLoseUpdates() {
        val threads = (1..20).map { Thread {
            SyncActivityLog.record(context, "recording", id, SyncActivityAction.CHECK_DELIVERY,
                SyncActivityOutcome.STARTED)
        } }
        threads.forEach { it.start() }; threads.forEach { it.join() }
        assertEquals(20, awaitCount(20).size)
    }
}
