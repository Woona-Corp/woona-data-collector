package com.example.myapplication.sync

import com.example.myapplication.localization.AppLanguage
import org.junit.Assert.*
import org.junit.Test

class SyncActivityLogTest {
    private val id = "10000000-0000-0000-0000-000000000001"
    private fun event(n: Int = 0) = SyncActivityEvent(
        "2026-11-07T12:00:00Z", "recording", id, "upload", "started", null)
        .copy(timestampUtc = "2026-11-07T12:00:00.${n.toString().padStart(3, '0')}Z")

    @Test fun capKeepsLast128ActualEventsWithoutInventingHistory() {
        val events = (0..199).map(::event)
        assertEquals(events.takeLast(128), SyncActivityLog.capped(events))
        assertTrue(SyncActivityLog.capped(emptyList()).isEmpty())
    }

    @Test fun recentFiltersVersionAndKindAndClampsLimit() {
        val other = event().copy(entityKind = "profile")
        val otherVersion = event().copy(entityId = "20000000-0000-0000-0000-000000000002")
        val events = listOf(event(1), other, otherVersion, event(2))
        assertEquals(listOf(event(2), event(1)), SyncActivityLog.filterRecent(events, "recording", id))
        assertEquals(listOf(event(2)), SyncActivityLog.filterRecent(events, "recording", id, 1))
        assertTrue(SyncActivityLog.filterRecent(events, "recording", id, -1).isEmpty())
        assertEquals(128, SyncActivityLog.filterRecent((0..199).map(::event), "recording", id, Int.MAX_VALUE).size)
        assertEquals(listOf(other), SyncActivityLog.filterRecent(events, "profile", id))
    }

    @Test fun noFreeTextSecretsPayloadsOrInvalidIdsAllowed() {
        for (secret in listOf("Bearer synthetic-secret", "{\"token\":\"synthetic\"}", "secret", "http_999", "a".repeat(500))) {
            assertNull(SyncActivityLog.safeCode(secret))
            assertFalse(SyncActivityLog.isSafe(event().copy(action = secret)))
            assertFalse(SyncActivityLog.isSafe(event().copy(outcome = secret)))
            assertFalse(SyncActivityLog.isSafe(event().copy(entityKind = secret)))
            assertFalse(SyncActivityLog.isSafe(event().copy(entityId = secret)))
            assertFalse(SyncActivityLog.isSafe(event().copy(code = secret)))
        }
        assertEquals("http_409", SyncActivityLog.safeCode("http_409"))
        assertEquals("offline", SyncActivityLog.safeCode("offline"))
        assertTrue(SyncActivityLog.isSafe(event().copy(entityKind = "account", entityId = "clinic_1.test")))
        assertFalse(SyncActivityLog.isSafe(event().copy(entityKind = "account", entityId = "a".repeat(65))))
        assertFalse(SyncActivityLog.isSafe(event().copy(timestampUtc = "not-a-date")))
        assertFalse(SyncActivityLog.isSafe(event().copy(timestampUtc = "2026-99-99T99:99:99Z")))
    }

    @Test fun invalidRowsDoNotDisplaceSafeEventsInPureCap() {
        val safe = event()
        assertEquals(listOf(safe), SyncActivityLog.capped(listOf(safe,
            safe.copy(action = "raw_json"), safe.copy(outcome = "token"))))
    }

    @Test fun labelsAreBilingualAndNeverEchoUnknownText() {
        assertEquals("Local save", syncActivityActionLabel("local_saved", AppLanguage.ENGLISH))
        assertEquals("Проверка доставки", syncActivityActionLabel("check_delivery", AppLanguage.RUSSIAN))
        assertEquals("Waiting for network", syncActivityOutcomeLabel("waiting_network", AppLanguage.ENGLISH))
        assertEquals("Успешно", syncActivityOutcomeLabel("succeeded", AppLanguage.RUSSIAN))
        assertEquals("Unknown action", syncActivityActionLabel("Bearer synthetic", AppLanguage.ENGLISH))
        assertEquals("Неизвестный результат", syncActivityOutcomeLabel("raw payload", AppLanguage.RUSSIAN))
        SyncActivityAction.entries.forEach {
            assertFalse(syncActivityActionLabel(it.value, AppLanguage.ENGLISH).startsWith("Unknown"))
        }
        SyncActivityOutcome.entries.forEach {
            assertFalse(syncActivityOutcomeLabel(it.value, AppLanguage.ENGLISH).startsWith("Unknown"))
        }
    }
}
