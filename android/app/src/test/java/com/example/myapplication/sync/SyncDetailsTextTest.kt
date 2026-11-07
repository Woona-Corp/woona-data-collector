package com.example.myapplication.sync

import com.example.myapplication.localization.AppLanguage
import org.junit.Assert.*
import org.junit.Test

class SyncDetailsTextTest {
    @Test fun redactionIsIdempotentForStorageAndRepeatedPresentation() {
        val samples = listOf(
            "HTTP409...Authorization: Bearer private-fixture",
            "Authorization: Basic private-fixture",
            """{"token":"private-fixture","Authorization":"Bearer private-fixture"}""",
            "https://user:private-fixture@host/path?unknown=private-fixture#private-fixture",
            "Bearer private-fixture",
        )
        samples.forEach { raw ->
            val once = redactSyncDetails(raw)
            assertEquals(once, redactSyncDetails(once))
            assertFalse(once.contains("private-fixture"))
        }
        assertEquals("HTTP409...Authorization: [redacted]", redactSyncDetails(samples.first()))
    }

    @Test fun signedAndUnknownUrlValuesAndFragmentsAreRemoved() {
        val raw = "HTTP 409 requestId=req-fixture https://user:sentinel-user@host.test/path?X-AmZ-Signature=sentinel-sign&unknown=sentinel-unknown#sentinel-fragment " +
            "HTTPS://host.test/path%3funknown%3dsentinel-encoded%23sentinel-hash " +
            "https%3A%2F%2Fuser:sentinel-user%40host.test/path%3Fkey%3Dsentinel-full"
        val text = redactSyncDetails(raw)
        assertFalse(text.contains("sentinel"))
        assertTrue(text.contains("host.test/path"))
        assertTrue(text.contains("HTTP 409 requestId=req-fixture"))
    }

    @Test fun labelsMixedCaseMultilineAndExactUnlabelledTokenAreRemoved() {
        val text = redactSyncDetails("""aUtHoRiZaTiOn:
            BeArEr sentinel-auth
            {"apiKey":"sentinel-api","PASSWORD":"sentinel-password","refresh_token":"sentinel-refresh"}
            Authorization: Basic sentinel-basic
            reflected sentinel-configured
        """.trimIndent(), "sentinel-configured")
        assertFalse(text.contains("sentinel"))
    }

    @Test fun secretsAreRemovedFromDisplayEvidence() {
        val text = redactSyncDetails("""Authorization: Bearer secret-value {"token":"private-token", "access_token":"private-access"} https://user:pass@host/path?token=private-query""")
        listOf("secret-value", "private-token", "private-access", "user:pass", "private-query").forEach { assertFalse(it, text.contains(it)) }
        assertTrue(text.contains("[redacted]"))
    }

    @Test fun unknownJsonIsNeverTheHumanSummary() {
        val raw = """HTTP 520 {"secret":"never-show", "unexpected":"raw-server-json"}"""
        val summary = syncFailureSummary(raw, AppLanguage.ENGLISH)
        assertFalse(summary.contains("never-show"))
        assertFalse(summary.contains("raw-server-json"))
    }

    @Test fun identityNamesAndIdsAreNotInferredFromTheServerPayload() {
        val text = serverSyncErrorText("""Server returned HTTP 409: {"code":"animal_id_already_exists","animalId":"not-local","name":"unknown-dog"}""", AppLanguage.RUSSIAN)
        assertFalse(text.contains("not-local")); assertFalse(text.contains("unknown-dog"))
        assertTrue(text.contains("Эта запись связана с новой карточкой"))
        assertTrue(animalIdentityConflictText(AppLanguage.RUSSIAN, "local-42").contains("ID local-42"))
    }
}
