package com.example.myapplication.data

import org.junit.Assert.*
import org.junit.Test

class SheetQuestionnaireParityTest {
    private val dog = DogQuestionnaire(schemaVersion = 2, animalId = "animal", numberOrName = "Dog")
    private val session = SessionQuestionnaire(schemaVersion = 2, sessionLabel = "Session", plannedActivities = listOf("walk"))

    @Test fun nameAndSessionLabelBoundsCountRawUnicodeScalars() {
        assertTrue(dog.copy(numberOrName = "🐕".repeat(100)).validateSheet().isValid)
        assertTrue(dog.copy(numberOrName = "🐕".repeat(101)).validateSheet().errors.containsKey("numberOrName"))
        assertTrue(session.copy(sessionLabel = "🐕".repeat(100)).validateSheet().isValid)
        assertTrue(session.copy(sessionLabel = "🐕".repeat(101)).validateSheet().errors.containsKey("sessionLabel"))
        assertTrue(dog.copy(numberOrName = "e\u0301".repeat(51)).validateSheet().errors.containsKey("numberOrName"))
        assertTrue(session.copy(sessionLabel = "e\u0301".repeat(51)).validateSheet().errors.containsKey("sessionLabel"))
    }

    @Test fun requiredNamesUsePinnedPythonWhitespaceWithoutChangingStoredValues() {
        for (blank in listOf("\u0085", "\u001c\u001d\u001e\u001f", " \u00a0\u3000")) {
            assertTrue(dog.copy(numberOrName = blank).validateSheet().errors.containsKey("numberOrName"))
            assertTrue(session.copy(sessionLabel = blank).validateSheet().errors.containsKey("sessionLabel"))
        }
        val rawName = " \u0085Straße e\u0301 "
        val rawSession = "\u0085 Session \u0085"
        val profile = dog.copy(numberOrName = rawName)
        val recording = session.copy(sessionLabel = rawSession)
        assertTrue(profile.validateSheet().isValid)
        assertTrue(recording.validateSheet().isValid)
        assertEquals(rawName, profile.numberOrName)
        assertEquals(rawSession, recording.sessionLabel)
        assertTrue(dog.copy(numberOrName = "\u200b").validateSheet().isValid)
    }

    @Test fun optionalTextAndSpeciesUseScalarLimitsNotUtf16OrGraphemeCounts() {
        assertTrue(dog.copy(breedName = "🐕".repeat(100)).validateSheet().isValid)
        assertTrue(dog.copy(breedName = "e\u0301".repeat(60)).validateSheet().errors.containsKey("breedName"))
        assertTrue(dog.copy(notes = "🐕".repeat(2000)).validateSheet().isValid)
        assertTrue(dog.copy(notes = "e\u0301".repeat(1001)).validateSheet().errors.containsKey("notes"))
        assertTrue(dog.copy(species = "🐕".repeat(2000)).validateSheet().isValid)
        assertTrue(dog.copy(species = "x".repeat(2001)).validateSheet().errors.containsKey("species"))
        assertTrue(session.copy(operatorName = "🐕".repeat(150)).validateSheet().isValid)
        assertTrue(session.copy(operatorName = "e\u0301".repeat(76)).validateSheet().errors.containsKey("operatorName"))
        assertTrue(session.copy(notes = "🐕".repeat(2000)).validateSheet().isValid)
        assertTrue(session.copy(notes = "e\u0301".repeat(1001)).validateSheet().errors.containsKey("notes"))
    }

    @Test fun compatibilityFreeTextAndMetadataFieldsAlsoRespectServerScalarLimits() {
        val tooLong = "x".repeat(2001)
        val dogErrors = dog.copy(breedStatus = tooLong, size = tooLong, ageStatus = tooLong,
            savedAtLocal = tooLong, chronicLameness = tooLong).validateSheet().errors
        assertTrue(dogErrors.keys.containsAll(listOf("breedStatus", "size", "ageStatus", "savedAtLocal", "chronicLameness")))
        val sessionErrors = session.copy(activityGroup = tooLong, activityType = tooLong,
            location = tooLong, surface = tooLong, sensorPosition = tooLong,
            savedAtLocal = tooLong, animalId = tooLong, sessionDate = tooLong,
            startTime = tooLong, endTime = tooLong).validateSheet().errors
        assertTrue(sessionErrors.keys.containsAll(listOf("activityGroup", "activityType", "location", "surface",
            "sensorPosition", "savedAtLocal", "animalId", "sessionDate", "startTime", "endTime")))
        val raw = "🐕".repeat(2000)
        val profile = dog.copy(breedStatus = raw, savedAtLocal = raw, chronicLameness = raw)
        val recording = session.copy(activityGroup = raw, savedAtLocal = raw, animalId = raw)
        assertTrue(profile.validateSheet().isValid)
        assertTrue(recording.validateSheet().isValid)
        assertEquals(raw, profile.breedStatus)
        assertEquals(raw, recording.animalId)
    }

    @Test fun sessionCompatibilityMeasurementsRespectServerNumericBoundaries() {
        assertTrue(session.copy(pulseBpm = null, respirationPerMinute = null, bodyTemperatureC = null).validateSheet().isValid)
        for (value in listOf(20, 300)) assertTrue(session.copy(pulseBpm = value).validateSheet().isValid)
        for (value in listOf(19, 301)) assertTrue(session.copy(pulseBpm = value).validateSheet().errors.containsKey("pulseBpm"))
        for (value in listOf(1, 200)) assertTrue(session.copy(respirationPerMinute = value).validateSheet().isValid)
        for (value in listOf(0, 201)) assertTrue(session.copy(respirationPerMinute = value).validateSheet().errors.containsKey("respirationPerMinute"))
        for (value in listOf(30.0, 45.0)) assertTrue(session.copy(bodyTemperatureC = value).validateSheet().isValid)
        for (value in listOf(29.99, 45.01, Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            assertTrue(session.copy(bodyTemperatureC = value).validateSheet().errors.containsKey("bodyTemperatureC"))
        }
    }

    @Test fun observedSignsOnlyEnforcesTheServerArrayItemCount() {
        assertTrue(dog.copy(observedSigns = emptyList()).validateSheet().isValid)
        // V2 schema deliberately allows duplicate/empty/arbitrarily long string items.
        assertTrue(dog.copy(observedSigns = List(100) { "" }).validateSheet().isValid)
        assertTrue(dog.copy(observedSigns = List(100) { "x".repeat(2001) }).validateSheet().isValid)
        assertTrue(dog.copy(observedSigns = List(101) { "sign" }).validateSheet().errors.containsKey("observedSigns"))
    }

    @Test fun arrayShapeLimitsAndUniquenessApplyToActivityAndHeartModes() {
        for (kind in listOf("activity", "heart")) {
            val base = session.copy(sessionKind = kind)
            assertTrue(base.copy(plannedActivities = (1..30).map { "activity-$it" },
                surfaces = (1..30).map { "surface-$it" }).validateSheet().isValid)
            assertTrue(base.copy(plannedActivities = listOf("🐕".repeat(100)),
                surfaces = listOf("🐕".repeat(100))).validateSheet().isValid)
            for (invalid in listOf(listOf(""), listOf("x".repeat(101)), listOf("e\u0301".repeat(51)),
                listOf("duplicate", "duplicate"), (1..31).map { "item-$it" })) {
                assertTrue(base.copy(plannedActivities = invalid).validateSheet().errors.containsKey("plannedActivities"))
                assertTrue(base.copy(surfaces = invalid).validateSheet().errors.containsKey("surfaces"))
            }
            // Server item schema uses minLength, not a non-whitespace pattern.
            assertTrue(base.copy(plannedActivities = listOf(" "), surfaces = listOf("\u0085")).validateSheet().isValid)
        }
        assertTrue(session.copy(plannedActivities = emptyList()).validateSheet().errors.containsKey("plannedActivities"))
        assertTrue(session.copy(sessionKind = "heart", plannedActivities = emptyList(), surfaces = emptyList()).validateSheet().isValid)
    }
}
