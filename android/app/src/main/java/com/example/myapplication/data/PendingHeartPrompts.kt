package com.example.myapplication.data

import android.content.Context

/** IDs only: retain a completed heart prompt until the operator saves or dismisses it. */
internal class PendingHeartPrompts(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("woona_pending_heart_prompts", Context.MODE_PRIVATE)

    fun ids(): Set<String> = synchronized(lock) { preferences.getStringSet(KEY, emptySet()).orEmpty().toSet() }

    fun add(id: String): Boolean = synchronized(lock) {
        preferences.edit().putStringSet(KEY, ids() + id).commit()
    }

    fun remove(id: String): Boolean = synchronized(lock) {
        preferences.edit().putStringSet(KEY, ids() - id).commit()
    }

    /** Persist the intent before changing any active row to interrupted. A failed
     * write leaves the rows active so the entire recovery can be retried. */
    fun recoverInterrupted(database: WoonaDatabase, persist: (Set<String>) -> Boolean = ::addAll) {
        val candidates = database.readableDatabase.query(
            "recordings", arrayOf("id", "questionnaire_json"),
            "status IN (?, ?)", arrayOf("preparing", "recording"), null, null, null,
        ).use { cursor ->
            buildSet {
                while (cursor.moveToNext()) {
                    if (cursor.isNull(1)) continue
                    val questionnaire = sessionQuestionnaireFromJson(cursor.getString(1))
                    if (questionnaire.sessionKind == "heart" && questionnaire.heartQuestionnaire == null) add(cursor.getString(0))
                }
            }
        }
        if (candidates.isNotEmpty() && !persist(candidates)) {
            throw java.io.IOException("Could not persist recovered heart questionnaire prompts")
        }
        database.interruptUnfinished()
    }

    private fun addAll(values: Set<String>): Boolean = synchronized(lock) {
        preferences.edit().putStringSet(KEY, ids() + values).commit()
    }

    companion object {
        private const val KEY = "recording_ids"
        private val lock = Any()
    }
}
