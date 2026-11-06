package com.example.myapplication.data

import org.junit.Assert.*
import org.junit.Test

class HeartQuestionnaireRegressionTest {
    private val complete = HeartQuestionnaire(
        answers = HEART_OPTIONS.keys.filter { it != "acuteHeartRateFactors" }.associateWith { "unknown" },
        acuteHeartRateFactors = listOf("unknown"),
    )

    @Test fun hiddenOverlengthDetailsDoNotBlockSave() {
        for (answer in listOf("no", "unknown")) {
            val draft = complete.copy(answers = complete.answers + mapOf("knownHeartCondition" to answer, "heartRelevantMedication" to answer),
                knownHeartConditionDetails = "x".repeat(2001), heartRelevantMedicationDetails = "x".repeat(2001), referenceArtifact = "x".repeat(2001))
            assertTrue("Hidden details for $answer: ${draft.validate().errors}", draft.validate().isValid)
        }
    }

    @Test fun visibleOverlengthDetailsHaveSpecificFieldKeys() {
        val draft = complete.copy(answers = complete.answers + mapOf("knownHeartCondition" to "yes", "heartRelevantMedication" to "yes", "referenceMethod" to "ecg"),
            knownHeartConditionDetails = "x".repeat(2001), heartRelevantMedicationDetails = "x".repeat(2001), referenceArtifact = "x".repeat(2001))
        assertEquals(setOf("knownHeartConditionDetails", "heartRelevantMedicationDetails", "referenceArtifact"), draft.validate().errors.keys)
        assertTrue(draft.copy(knownHeartConditionDetails = "x".repeat(2000), heartRelevantMedicationDetails = "x".repeat(2000), referenceArtifact = "x".repeat(2000)).validate().isValid)
    }
}
