package com.example.myapplication.data

/** Python str.strip() whitespace, then Unicode default case folding (not locale lowercasing).
 * Comparison only: never rewrite questionnaire JSON or its immutable content hash.
 */
internal fun normalizedAnimalIdentity(value: String): String = buildString {
    stripAnimalIdentity(value).codePoints().forEach { scalar ->
        val folded = animalIdentityCaseFolding[scalar]
        if (folded != null) append(folded) else appendCodePoint(scalar)
    }
}

internal fun stripAnimalIdentity(value: String): String = value.trim {
    it in '\u0009'..'\u000d' || it in '\u001c'..'\u0020' ||
        it == '\u0085' || it == '\u00a0' || it == '\u1680' || it in '\u2000'..'\u200a' ||
        it == '\u2028' || it == '\u2029' || it == '\u202f' || it == '\u205f' || it == '\u3000'
}

class LocalAnimalIdentityConflict(
    val animalId: String,
    val existingProfileId: String,
    val existingProfileName: String,
    val existingAccountId: String?,
) : IllegalArgumentException(
    // Safe fallback even if a caller does not yet use the localized formatter.
    "ID животного уже используется другой карточкой. Проверьте аккаунт и выберите существующее животное; черновик сохранён / Animal ID already belongs to another profile. Check the account and select the existing animal; your draft is preserved",
)

/** Called inside saveProfile's write transaction; includes archived cards and historical aliases.
 * Stream rows rather than collecting the full history; SQLite serializes concurrent writers.
 */
internal fun WoonaDatabase.requireAvailableAnimalIdentity(animalId: String?, dogId: String) {
    val identity = animalId?.let(::normalizedAnimalIdentity)?.takeIf { it.isNotEmpty() } ?: return
    writableDatabase.rawQuery(
        """SELECT d.id,d.number_or_name,d.account_id,v.questionnaire_json
           FROM dog_profile_versions v JOIN dogs d ON d.id=v.dog_id
           WHERE d.id<>? ORDER BY d.id,v.id""",
        arrayOf(dogId),
    ).use { cursor ->
        while (cursor.moveToNext()) {
            val previous = dogQuestionnaireFromJson(cursor.getString(3)).animalId ?: continue
            if (normalizedAnimalIdentity(previous) == identity) {
                throw LocalAnimalIdentityConflict(requireNotNull(animalId), cursor.getString(0), cursor.getString(1), cursor.getString(2))
            }
        }
    }
}
