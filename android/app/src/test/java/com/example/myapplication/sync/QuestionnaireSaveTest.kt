package com.example.myapplication.sync

import com.example.myapplication.data.SessionQuestionnaire
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class QuestionnaireSaveTest {
    private val draft = SessionQuestionnaire(sessionLabel = "retained", savedAtLocal = "local-time")
    private data class Receipt(val answers: SessionQuestionnaire, val revision: Int)
    private fun conflict() = ServerHttpException(409, "questionnaire_revision_conflict", emptyMap())

    @Test fun lostSaveResponseThenRetryAcceptsAlreadyCommittedAnswersWithoutSecondWrite() {
        var persisted: Receipt? = null
        var readCount = 0
        val canonical = Receipt(draft.copy(savedAtLocal = "server-time"), 3)
        reconcileQuestionnaireSave(draft, update = { throw conflict() },
            read = { readCount++; canonical }, answers = { it.answers }, revision = { it.revision }, persist = { persisted = it })
        assertEquals(1, readCount)
        assertEquals(canonical, persisted)
        assertEquals("retained", draft.sessionLabel)
    }

    @Test fun genuineRevisionConflictNeverPersistsOrOverwritesTheDraft() {
        val canonical = Receipt(draft.copy(sessionLabel = "someone else's edit"), 8)
        var persisted = false
        try {
            reconcileQuestionnaireSave(draft, update = { throw conflict() }, read = { canonical },
                answers = { it.answers }, revision = { it.revision }, persist = { persisted = true })
            fail("Different answers require explicit review")
        } catch (error: QuestionnaireRevisionConflict) {
            assertEquals(8, error.revision)
            assertEquals(canonical.answers, error.questionnaire)
        }
        assertFalse(persisted)
        assertEquals("retained", draft.sessionLabel)
    }

    @Test fun localDatabaseFailurePropagatesAfterServerSaveAndRetryReconcilesReceipt() {
        val canonical = Receipt(draft, 2)
        try {
            reconcileQuestionnaireSave(draft, update = { canonical }, read = { error("No read on success") },
                answers = { it.answers }, revision = { it.revision }, persist = { throw IOException("database unavailable") })
            fail("Local failure must not be reported as success")
        } catch (error: IOException) { assertEquals("database unavailable", error.message) }
        var persisted: Receipt? = null
        reconcileQuestionnaireSave(draft, update = { throw conflict() }, read = { canonical },
            answers = { it.answers }, revision = { it.revision }, persist = { persisted = it })
        assertEquals(canonical, persisted)
    }

    @Test fun networkFailureDoesNotReadOrClaimSuccessAndOnly409IsReconciled() {
        for (failure in listOf(IOException("timeout"), ServerHttpException(403, "forbidden", emptyMap()))) {
            try {
                reconcileQuestionnaireSave<Receipt>(draft, update = { throw failure }, read = { error("Unexpected read") },
                    answers = { it.answers }, revision = { it.revision }, persist = { fail("Unexpected save") })
                fail("The caller must see the actual failure")
            } catch (error: IOException) { assertSame(failure, error) }
        }
    }
}
