package com.example.myapplication.sync

import com.example.myapplication.data.RemoteRecording
import com.example.myapplication.data.SessionQuestionnaire
import com.example.myapplication.data.sessionQuestionnaireFromJson

class QuestionnaireRevisionConflict(val questionnaire: SessionQuestionnaire, val revision: Int) :
    IllegalStateException("HTTP 409: questionnaire_revision_conflict — анкета изменена на сервере / questionnaire changed on the server")

fun questionnaireAnswersMatch(left: SessionQuestionnaire, right: SessionQuestionnaire): Boolean =
    left.copy(savedAtLocal = null) == right.copy(savedAtLocal = null)

/** A lost PUT response may follow a committed save. GET is read-only: accept an
 * identical result, or require the editor to review a different revision. */
fun <T> reconcileQuestionnaireSave(
    desired: SessionQuestionnaire,
    update: () -> T,
    read: () -> T,
    answers: (T) -> SessionQuestionnaire,
    revision: (T) -> Int,
    persist: (T) -> Unit,
) {
    val accepted = try { update() } catch (error: ServerHttpException) {
        if (error.status != 409) throw error
        val latest = read()
        val latestAnswers = answers(latest)
        if (!questionnaireAnswersMatch(desired, latestAnswers)) throw QuestionnaireRevisionConflict(latestAnswers, revision(latest))
        latest
    }
    persist(accepted)
}

fun saveQuestionnaireRevision(
    desired: SessionQuestionnaire,
    update: () -> RemoteRecording,
    read: () -> RemoteRecording,
    persist: (RemoteRecording) -> Unit,
) {
    reconcileQuestionnaireSave(desired, update, read,
        answers = { sessionQuestionnaireFromJson(it.sessionQuestionnaireJson) },
        revision = { it.questionnaireRevision }, persist = persist)
}
