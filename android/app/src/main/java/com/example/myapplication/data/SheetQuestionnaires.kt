package com.example.myapplication.data

import java.time.LocalDate
import java.time.LocalTime

/** V2 follows the supplied sheets. Blank optional answers stay blank/null. */
fun DogQuestionnaire.validateSheet(): QuestionnaireValidation {
    val errors = linkedMapOf<String, String>()
    if (animalId == null || stripAnimalIdentity(animalId).isEmpty() || animalId.codePointCount(0, animalId.length) > 100) errors["animalId"] = "Укажите ID животного (до 100 символов)"
    if (numberOrName.isBlank() || numberOrName.length > 100) errors["numberOrName"] = "Укажите кличку (до 100 символов)"
    for ((key, value, max) in listOf(
        Triple("shelterOrPlace", shelterOrPlace, 200), Triple("breedName", breedName, 100), Triple("resembles", resembles, 200),
        Triple("shavedAreasDetails", shavedAreasDetails, 500), Triple("diagnosesDetails", diagnosesDetails, 2000),
        Triple("housingDetails", housingDetails, 500), Triple("walksDescription", walksDescription, 500),
        Triple("notes", notes, 2000), Triple("medications", medications, 2000), Triple("history", history, 2000),
        Triple("specialistName", specialistName, 2000), Triple("diseaseCategory", diseaseCategory, 2000),
        Triple("diseaseCategoryDetails", diseaseCategoryDetails, 2000),
    )) if (value != null && value.length > max) errors[key] = "Максимум $max символов"
    if (ageYears != null && ageYears !in 0..40) errors["ageYears"] = "Укажите 0–40 лет"
    if (ageMonths != null && ageMonths !in 0..11) errors["ageMonths"] = "Укажите 0–11 месяцев"
    if (weightKg != null && (!weightKg.isFinite() || weightKg <= 0 || weightKg > 150)) errors["weightKg"] = "Вес должен быть >0 и ≤150 кг"
    if (bodyConditionScore != null && bodyConditionScore !in 1..9) errors["bodyConditionScore"] = "BCS: 1–9"
    if (neckCircumferenceCm != null && (!neckCircumferenceCm.isFinite() || neckCircumferenceCm <= 0 || neckCircumferenceCm > 150)) errors["neckCircumferenceCm"] = "Обхват должен быть >0 и ≤150 см; оставьте пустым, если не измерен"
    return QuestionnaireValidation(errors)
}

fun SessionQuestionnaire.validateSheet(): QuestionnaireValidation {
    val errors = linkedMapOf<String, String>()
    if (sessionLabel.isBlank() || sessionLabel.length > 100) errors["sessionLabel"] = "Укажите номер сессии (до 100 символов)"
    for ((key, value, max) in listOf(
        Triple("operatorName", operatorName, 150), Triple("activityDetails", activityDetails, 1000),
        Triple("surfaceDetails", surfaceDetails, 300), Triple("sensorPositionDetails", sensorPositionDetails, 300),
        Triple("preMeasurementStateDetails", preMeasurementStateDetails, 500), Triple("notes", notes, 2000),
        Triple("lastMedicationAt", lastMedicationAt, 2000), Triple("specialistName", specialistName, 2000),
    )) if (value != null && value.length > max) errors[key] = "Максимум $max символов"
    if (sessionKind !in setOf(null, "activity", "heart")) errors["sessionKind"] = "Выберите вид сессии"
    heartQuestionnaire?.validate()?.errors?.let { errors.putAll(it) }
    if (sessionKind != "heart" && (plannedActivities.isEmpty() || plannedActivities.any { it.isBlank() } || plannedActivities.distinct().size != plannedActivities.size)) errors["plannedActivities"] = "Выберите формат записи"
    if (surfaces.any { it.isBlank() } || surfaces.distinct().size != surfaces.size) errors["surfaces"] = "Проверьте поверхности"
    if (airTemperatureC != null && (!airTemperatureC.isFinite() || airTemperatureC !in -60.0..70.0)) errors["airTemperatureC"] = "Температура: −60…70 °C"
    if (durationMinutes != null && (!durationMinutes.isFinite() || durationMinutes < 0)) errors["durationMinutes"] = "Продолжительность должна быть ≥0"
    if (!sessionDate.isNullOrBlank() && runCatching { LocalDate.parse(sessionDate) }.isFailure) errors["sessionDate"] = "Дата: ГГГГ-ММ-ДД"
    for ((key, value) in listOf("startTime" to startTime, "endTime" to endTime)) {
        if (!value.isNullOrBlank() && runCatching { LocalTime.parse(value) }.isFailure) errors[key] = "Время: ЧЧ:ММ"
    }
    return QuestionnaireValidation(errors)
}
