package com.example.myapplication.data

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

val HEART_OPTIONS = linkedMapOf(
    "knownHeartCondition" to listOf("no" to "Нет", "yes" to "Да", "unknown" to "Неизвестно"),
    "heartRelevantMedication" to listOf("no" to "Нет", "yes" to "Да", "unknown" to "Неизвестно"),
    "preRecordingState" to listOf("sleeping" to "Спала", "lying_calm" to "Спокойно лежала", "awake_calm" to "Спокойно бодрствовала", "active" to "Гуляла, бегала или играла", "unknown" to "Неизвестно"),
    "actualActivity" to listOf("rest" to "Спала или находилась в покое", "walking" to "Ходила", "running_playing" to "Бегала или играла", "changing" to "Активность менялась", "unknown" to "Неизвестно"),
    "acuteHeartRateFactors" to listOf("none" to "Нет", "stress" to "Стресс или испуг", "pain" to "Боль", "overheating" to "Перегрев", "unknown" to "Неизвестно"),
    "referenceMethod" to listOf("ecg" to "ЭКГ с временными метками", "polar_rr" to "Polar с интервалами между ударами и временными метками", "bpm_only" to "Только число ЧСС, измеренное вручную или прибором", "none" to "Нет", "unknown" to "Неизвестно"),
 )

/** One questionnaire belonging to a recording; dog identity and UTC bounds come from recording metadata. */
data class HeartQuestionnaire(
    val answers: Map<String, String> = emptyMap(),
    val acuteHeartRateFactors: List<String> = emptyList(),
    val knownHeartConditionDetails: String? = null,
    val heartRelevantMedicationDetails: String? = null,
    val referenceArtifact: String? = null,
    val referenceBpm: Double? = null,
    val referenceMeasuredAtUtc: String? = null,
) {
    fun validate(): QuestionnaireValidation {
        val errors = linkedMapOf<String, String>()
        HEART_OPTIONS.forEach { (key, options) ->
            val selected = if (key == "acuteHeartRateFactors") acuteHeartRateFactors else listOf(answers[key].orEmpty())
            if (selected.isEmpty() || selected.any { value -> options.none { it.first == value } }) errors[key] = "Выберите ответ"
        }
        if (acuteHeartRateFactors.distinct().size != acuteHeartRateFactors.size ||
            (acuteHeartRateFactors.size > 1 && acuteHeartRateFactors.any { it in setOf("none", "unknown") })) {
            errors["acuteHeartRateFactors"] = "Нет и Неизвестно выбираются отдельно"
        }
        if (answers["referenceMethod"] in setOf("ecg", "polar_rr") && referenceArtifact.isNullOrBlank()) errors["referenceArtifact"] = "Укажите запись и временную привязку"
        if (answers["referenceMethod"] == "bpm_only") {
            if (referenceBpm == null || !referenceBpm.isFinite() || referenceBpm <= 0) errors["referenceBpm"] = "Введите положительную ЧСС"
            if (runCatching { Instant.parse(referenceMeasuredAtUtc) }.isFailure) errors["referenceMeasuredAtUtc"] = "Введите время UTC, например 2026-10-05T12:00:00Z"
        }
        // Validate only details serialized for the selected answer. Retain inactive
        // draft text so changing an answer back does not discard the operator's work.
        val activeDetails = linkedMapOf<String, String?>()
        if (answers["knownHeartCondition"] == "yes") activeDetails["knownHeartConditionDetails"] = knownHeartConditionDetails
        if (answers["heartRelevantMedication"] == "yes") activeDetails["heartRelevantMedicationDetails"] = heartRelevantMedicationDetails
        if (answers["referenceMethod"] in setOf("ecg", "polar_rr")) activeDetails["referenceArtifact"] = referenceArtifact
        activeDetails.forEach { (key, value) ->
            if (value != null && value.length > 2000) errors[key] = "Максимум 2000 символов"
        }
        return QuestionnaireValidation(errors)
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("schemaVersion", 1)
        fun answer(key: String, value: String): JSONObject = JSONObject().put("key", value)
            .put("text", HEART_OPTIONS.getValue(key).firstOrNull { it.first == value }?.second.orEmpty())
        HEART_OPTIONS.keys.forEach { key ->
            if (key == "acuteHeartRateFactors") put(key, JSONArray(acuteHeartRateFactors.map { answer(key, it) }))
            else put(key, answer(key, answers[key].orEmpty()))
        }
        put("knownHeartConditionDetails", if (answers["knownHeartCondition"] == "yes") knownHeartConditionDetails ?: JSONObject.NULL else JSONObject.NULL)
        put("heartRelevantMedicationDetails", if (answers["heartRelevantMedication"] == "yes") heartRelevantMedicationDetails ?: JSONObject.NULL else JSONObject.NULL)
        put("referenceArtifact", if (answers["referenceMethod"] in setOf("ecg", "polar_rr")) referenceArtifact ?: JSONObject.NULL else JSONObject.NULL)
        put("referenceBpm", if (answers["referenceMethod"] == "bpm_only") JSONObject().put("bpm", referenceBpm).put("measuredAtUtc", referenceMeasuredAtUtc) else JSONObject.NULL)
    }

    companion object {
        fun fromJson(value: JSONObject): HeartQuestionnaire = HeartQuestionnaire(
            answers = HEART_OPTIONS.keys.filter { it != "acuteHeartRateFactors" }.associateWith { value.getJSONObject(it).getString("key") },
            acuteHeartRateFactors = value.getJSONArray("acuteHeartRateFactors").let { array -> (0 until array.length()).map { array.getJSONObject(it).getString("key") } },
            knownHeartConditionDetails = value.optString("knownHeartConditionDetails").takeUnless { it == "null" || it.isBlank() },
            heartRelevantMedicationDetails = value.optString("heartRelevantMedicationDetails").takeUnless { it == "null" || it.isBlank() },
            referenceArtifact = value.optString("referenceArtifact").takeUnless { it == "null" || it.isBlank() },
            referenceBpm = value.optJSONObject("referenceBpm")?.getDouble("bpm"),
            referenceMeasuredAtUtc = value.optJSONObject("referenceBpm")?.getString("measuredAtUtc"),
        )
    }
}

fun SessionQuestionnaire.readyForSync(): Boolean = sessionKind != "heart" || heartQuestionnaire?.validate()?.isValid == true

fun WoonaDatabase.heartQuestionnaireDraft(recordingId: String): HeartQuestionnaire {
    val recording = requireNotNull(recording(recordingId))
    val reference = recording.artifacts.firstOrNull { it.type == ArtifactType.ECG }
        ?: recording.artifacts.firstOrNull { it.type == ArtifactType.RR && it.referenceMetadataJson?.contains("Polar", ignoreCase = true) == true }
    if (reference != null) return HeartQuestionnaire(
        answers = mapOf("referenceMethod" to if (reference.type == ArtifactType.ECG) "ecg" else "polar_rr"),
        referenceArtifact = "${reference.fileName}; ${reference.referenceMetadataJson}",
    )
    val ecg = recording.artifacts.firstOrNull { it.fileName == "polar_ecg.csv" }
    if (ecg != null && resolveRelativePath(ecg.relativePath).isFile) {
        val row = resolveRelativePath(ecg.relativePath).useLines { it.drop(1).firstOrNull() }
        if (!row.isNullOrBlank()) return HeartQuestionnaire(answers = mapOf("referenceMethod" to "ecg"), referenceArtifact = "${ecg.fileName}; host_utc / polar_timestamp_ns; ${row.substringBefore(',')}")
    }
    val hr = recording.artifacts.firstOrNull { it.fileName == "polar_hr.csv" }
    if (hr != null && resolveRelativePath(hr.relativePath).isFile) {
        val rrRow = resolveRelativePath(hr.relativePath).useLines { lines ->
            lines.drop(1).firstOrNull { it.substringAfterLast(',').toIntOrNull()?.let { rr -> rr > 0 } == true }
        }
        if (rrRow != null) return HeartQuestionnaire(answers = mapOf("referenceMethod" to "polar_rr"), referenceArtifact = "${hr.fileName}; host_utc; ${rrRow.substringBefore(',')}")
        val fields = resolveRelativePath(hr.relativePath).useLines { it.drop(1).firstOrNull()?.split(',') }
        val bpm = fields?.getOrNull(1)?.toDoubleOrNull()
        if (bpm != null && bpm.isFinite() && bpm > 0 && runCatching { Instant.parse(fields.first()) }.isSuccess) {
            return HeartQuestionnaire(answers = mapOf("referenceMethod" to "bpm_only"), referenceBpm = bpm, referenceMeasuredAtUtc = fields.first())
        }
    }
    return HeartQuestionnaire()
}

data class ReferenceMetadata(
    val source: String,
    val startedAtUtc: String,
    val endedAtUtc: String,
    val offsetFromRecordingMs: Double? = null,
    val notes: String? = null,
) {
    fun validate(): QuestionnaireValidation {
        val errors = linkedMapOf<String, String>()
        if (source.isBlank() || source.length > 200) errors["source"] = "Укажите устройство/источник (до 200 символов)"
        val start = runCatching { Instant.parse(startedAtUtc) }.getOrNull()
        val end = runCatching { Instant.parse(endedAtUtc) }.getOrNull()
        if (start == null) errors["startedAtUtc"] = "Введите время начала UTC"
        if (end == null || (start != null && end < start)) errors["endedAtUtc"] = "Введите окончание не раньше начала"
        if (offsetFromRecordingMs != null && !offsetFromRecordingMs.isFinite()) errors["offsetFromRecordingMs"] = "Введите число или оставьте пустым"
        if (notes != null && notes.length > 2000) errors["notes"] = "Максимум 2000 символов"
        return QuestionnaireValidation(errors)
    }

    fun toJson(): String = JSONObject().put("source", source).put("startedAtUtc", startedAtUtc)
        .put("endedAtUtc", endedAtUtc).put("offsetFromRecordingMs", offsetFromRecordingMs ?: JSONObject.NULL)
        .put("notes", notes ?: JSONObject.NULL).toString()
}
