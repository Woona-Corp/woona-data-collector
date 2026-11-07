package com.example.myapplication.sync

import com.example.myapplication.data.LocalAnimalIdentityConflict
import com.example.myapplication.data.DogQuestionnaire
import com.example.myapplication.data.stripAnimalIdentity
import com.example.myapplication.data.validate
import com.example.myapplication.localization.AppLanguage
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class LocalAnimalIdentityTextTest {
    private val conflict = LocalAnimalIdentityConflict("animal", "private-uuid", "Secret card", "account")

    @Test fun crossAccountErrorsNeverRevealCardOrOfferSelectionInWrongScope() {
        for (language in AppLanguage.entries) {
            val text = localAnimalIdentityConflictText(conflict, "other", language)
            assertFalse(text.contains("Secret card"))
            assertFalse(text.contains("private-uuid"))
            assertFalse(conflict.message.orEmpty().contains("Secret card"))
        }
    }
    @Test fun sameAccountExplainsExistingCardAndKeepsDraft() {
        val en = localAnimalIdentityConflictText(conflict, " ACCOUNT ", AppLanguage.ENGLISH)
        assertTrue(en.contains("Secret card"))
        assertTrue(en.contains("draft is preserved"))
        assertTrue(localAnimalIdentityConflictText(conflict, "account", AppLanguage.RUSSIAN).contains("черновик"))
    }
    @Test fun localIdentityRequiredAndLengthRulesMatchServerUnicodeCharacters() {
        assertEquals("DOG", stripAnimalIdentity("\u0085\u001c DOG\u00a0"))
        assertEquals("\u200b", stripAnimalIdentity("\u200b"))
        val profile = DogQuestionnaire(schemaVersion = 2, numberOrName = "Dog", animalId = "\u0085")
        assertTrue(profile.validate().errors.containsKey("animalId"))
        assertTrue(profile.copy(animalId = "🐕".repeat(100)).validate().isValid)
        assertTrue(profile.copy(animalId = "🐕".repeat(101)).validate().errors.containsKey("animalId"))
    }

    @Test fun actualAttemptJournalUsesSafeCodesAndDistinctWaitingOutcomes() {
        assertEquals(SyncActivityOutcome.WAITING_NETWORK, IOException("offline private details").syncActivityOutcome())
        assertEquals("network_error", IOException("offline private details").syncActivityCode())
        val conflict = ServerHttpException(409, "private server response", emptyMap())
        assertEquals(SyncActivityOutcome.FAILED, conflict.syncActivityOutcome())
        assertEquals("http_409", conflict.syncActivityCode())
        val unavailable = ServerHttpException(503, "private server response", emptyMap())
        assertEquals(SyncActivityOutcome.FAILED, unavailable.syncActivityOutcome())
        assertEquals("http_503", unavailable.syncActivityCode())
        val rateLimited = ServerHttpException(429, "private server response", emptyMap())
        assertEquals(SyncActivityOutcome.FAILED, rateLimited.syncActivityOutcome())
        assertEquals("http_429", rateLimited.syncActivityCode())
        assertEquals("local_io", ServerTransferException("arbitrary_secret", "private details", true).syncActivityCode())
        assertEquals("validation_failed", IllegalArgumentException("private questionnaire").syncActivityCode())
    }

    @Test fun staleAndInvalidProfilesAreNotNetworkRetries() {
        for (code in listOf(400, 401, 403, 409, 422)) {
            assertFalse(ServerHttpException(code, "invalid or stale profile", emptyMap()).isRetryable())
        }
        for (code in listOf(408, 425, 429, 500, 503)) {
            assertTrue(ServerHttpException(code, "temporary", emptyMap()).isRetryable())
        }
        assertTrue(IOException("offline").isRetryable())
        assertFalse(IllegalArgumentException("invalid local questionnaire").isRetryable())
        assertFalse(ServerTransferException("invalid", "fix metadata").isRetryable())
    }
}
