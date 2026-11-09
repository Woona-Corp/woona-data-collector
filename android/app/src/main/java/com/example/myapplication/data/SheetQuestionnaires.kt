package com.example.myapplication.data

import java.time.LocalDate
import java.time.LocalTime

/** V2 follows the supplied sheets. Blank optional answers stay blank/null. */
fun DogQuestionnaire.validateSheet(): QuestionnaireValidation {
    val errors = linkedMapOf<String, String>()
    if (animalId == null || stripAnimalIdentity(animalId).isEmpty() || animalId.codePointCount(0, animalId.length) > 100) errors["animalId"] = "Укажите ID животного (до 100 символов)"
    if (stripAnimalIdentity(numberOrName).isEmpty() || numberOrName.codePointCount(0, numberOrName.length) > 100) errors["numberOrName"] = "Укажите кличку (до 100 символов)"
    for ((key, value, max) in listOf(
        Triple("shelterOrPlace", shelterOrPlace, 200), Triple("breedName", breedName, 100), Triple("resembles", resembles, 200),
        Triple("shavedAreasDetails", shavedAreasDetails, 500), Triple("diagnosesDetails", diagnosesDetails, 2000),
        Triple("housingDetails", housingDetails, 500), Triple("walksDescription", walksDescription, 500),
        Triple("notes", notes, 2000), Triple("medications", medications, 2000), Triple("history", history, 2000),
        Triple("specialistName", specialistName, 2000), Triple("diseaseCategory", diseaseCategory, 2000),
        Triple("diseaseCategoryDetails", diseaseCategoryDetails, 2000), Triple("species", species, 2000),
        Triple("breedStatus", breedStatus, 2000), Triple("size", size, 2000),
        Triple("ageStatus", ageStatus, 2000), Triple("ageSource", ageSource, 2000),
        Triple("sex", sex, 2000), Triple("sterilizationStatus", sterilizationStatus, 2000),
        Triple("weightStatus", weightStatus, 2000), Triple("bodyConditionStatus", bodyConditionStatus, 2000),
        Triple("muscleMass", muscleMass, 2000), Triple("neckCircumferenceStatus", neckCircumferenceStatus, 2000),
        Triple("coatLength", coatLength, 2000), Triple("undercoat", undercoat, 2000),
        Triple("shavedAreasStatus", shavedAreasStatus, 2000), Triple("diagnosesStatus", diagnosesStatus, 2000),
        Triple("housing", housing, 2000), Triple("walksStatus", walksStatus, 2000),
        Triple("cohabitants", cohabitants, 2000), Triple("shelterPermission", shelterPermission, 2000),
        Triple("notesStatus", notesStatus, 2000), Triple("savedAtLocal", savedAtLocal, 2000),
        Triple("chronicLameness", chronicLameness, 2000),
    )) if (value != null && value.codePointCount(0, value.length) > max) errors[key] = "Максимум $max символов"
    if (observedSigns.size > 100) errors["observedSigns"] = "Максимум 100 вариантов"
    if (ageYears != null && ageYears !in 0..40) errors["ageYears"] = "Укажите 0–40 лет"
    if (ageMonths != null && ageMonths !in 0..11) errors["ageMonths"] = "Укажите 0–11 месяцев"
    if (weightKg != null && (!weightKg.isFinite() || weightKg <= 0 || weightKg > 150)) errors["weightKg"] = "Вес должен быть >0 и ≤150 кг"
    if (bodyConditionScore != null && bodyConditionScore !in 1..9) errors["bodyConditionScore"] = "BCS: 1–9"
    if (neckCircumferenceCm != null && (!neckCircumferenceCm.isFinite() || neckCircumferenceCm <= 0 || neckCircumferenceCm > 150)) errors["neckCircumferenceCm"] = "Обхват должен быть >0 и ≤150 см; оставьте пустым, если не измерен"
    return QuestionnaireValidation(errors)
}

fun SessionQuestionnaire.validateSheet(): QuestionnaireValidation {
    val errors = linkedMapOf<String, String>()
    if (stripAnimalIdentity(sessionLabel).isEmpty() || sessionLabel.codePointCount(0, sessionLabel.length) > 100) errors["sessionLabel"] = "Укажите номер сессии (до 100 символов)"
    for ((key, value, max) in listOf(
        Triple("operatorName", operatorName, 150), Triple("activityDetails", activityDetails, 1000),
        Triple("surfaceDetails", surfaceDetails, 300), Triple("sensorPositionDetails", sensorPositionDetails, 300),
        Triple("preMeasurementStateDetails", preMeasurementStateDetails, 500), Triple("notes", notes, 2000),
        Triple("lastMedicationAt", lastMedicationAt, 2000), Triple("specialistName", specialistName, 2000),
        Triple("activityGroup", activityGroup, 2000), Triple("activityType", activityType, 2000),
        Triple("location", location, 2000), Triple("surface", surface, 2000),
        Triple("airTemperatureStatus", airTemperatureStatus, 2000), Triple("sensorPosition", sensorPosition, 2000),
        Triple("collarTightness", collarTightness, 2000), Triple("preMeasurementState", preMeasurementState, 2000),
        Triple("pulseStatus", pulseStatus, 2000), Triple("respirationStatus", respirationStatus, 2000),
        Triple("bodyTemperatureStatus", bodyTemperatureStatus, 2000), Triple("savedAtLocal", savedAtLocal, 2000),
        Triple("animalId", animalId, 2000), Triple("sessionDate", sessionDate, 2000),
        Triple("startTime", startTime, 2000), Triple("endTime", endTime, 2000),
    )) if (value != null && value.codePointCount(0, value.length) > max) errors[key] = "Максимум $max символов"
    if (sessionKind !in setOf(null, "activity", "heart")) errors["sessionKind"] = "Выберите вид сессии"
    heartQuestionnaire?.validate()?.errors?.let { errors.putAll(it) }
    // JSON Schema array shape applies even to heart sessions. Only the extra
    // requirement to choose a nonempty activity list is conditional on kind.
    if ((sessionKind != "heart" && plannedActivities.isEmpty()) || plannedActivities.size > 30 ||
        plannedActivities.any { it.codePointCount(0, it.length) !in 1..100 } ||
        plannedActivities.distinct().size != plannedActivities.size) errors["plannedActivities"] = "Выберите формат записи"
    if (surfaces.size > 30 || surfaces.any { it.codePointCount(0, it.length) !in 1..100 } ||
        surfaces.distinct().size != surfaces.size) errors["surfaces"] = "Проверьте поверхности"
    if (airTemperatureC != null && (!airTemperatureC.isFinite() || airTemperatureC !in -60.0..70.0)) errors["airTemperatureC"] = "Температура: −60…70 °C"
    if (pulseBpm != null && pulseBpm !in 20..300) errors["pulseBpm"] = "Пульс: 20–300 уд/мин"
    if (respirationPerMinute != null && respirationPerMinute !in 1..200) errors["respirationPerMinute"] = "Дыхание: 1–200 в минуту"
    if (bodyTemperatureC != null && (!bodyTemperatureC.isFinite() || bodyTemperatureC !in 30.0..45.0)) errors["bodyTemperatureC"] = "Температура тела: 30–45 °C"
    if (durationMinutes != null && (!durationMinutes.isFinite() || durationMinutes < 0)) errors["durationMinutes"] = "Продолжительность должна быть ≥0"
    if (!sessionDate.isNullOrBlank() && runCatching { LocalDate.parse(sessionDate) }.isFailure) errors["sessionDate"] = "Дата: ГГГГ-ММ-ДД"
    for ((key, value) in listOf("startTime" to startTime, "endTime" to endTime)) {
        if (!value.isNullOrBlank() && runCatching { LocalTime.parse(value) }.isFailure) errors[key] = "Время: ЧЧ:ММ"
    }
    return QuestionnaireValidation(errors)
}
