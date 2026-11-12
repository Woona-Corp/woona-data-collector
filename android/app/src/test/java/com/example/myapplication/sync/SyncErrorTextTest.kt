package com.example.myapplication.sync

import com.example.myapplication.localization.AppLanguage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncErrorTextTest {
    @Test fun identityConflictExplainsRecoveryAndAccountInBothLanguages() {
        val error = """Server returned HTTP 409: {"code": "animal_id_already_exists"}"""
        assertTrue(serverSyncErrorText(error, AppLanguage.RUSSIAN).contains("историческую привязку"))
        assertTrue(serverSyncErrorText(error, AppLanguage.ENGLISH).contains("historical identity"))
        assertTrue(serverSyncErrorText(error, AppLanguage.ENGLISH).contains("does not rewrite an existing recording"))
    }
    @Test fun otherConflictsAndMalformedResponsesKeepOriginalDetails() {
        for (error in listOf("Server returned HTTP 409: {\"code\":\"revision_conflict\"}",
            "Server returned HTTP 500: {\"code\":\"animal_id_already_exists\"}", "offline")) {
            assertEquals(error, serverSyncErrorText(error, AppLanguage.RUSSIAN))
        }
    }
}
