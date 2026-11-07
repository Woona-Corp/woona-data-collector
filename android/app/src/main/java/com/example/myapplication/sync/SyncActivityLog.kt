package com.example.myapplication.sync

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Only actual events, never a reconstruction from the current sync status. IDs are
 * profile VERSION UUIDs / recording UUIDs / account identifiers (not animal names).
 * No messages, request bodies, URLs, headers or credentials belong in this journal.
 */
data class SyncActivityEvent(
    val timestampUtc: String,
    val entityKind: String,
    val entityId: String,
    val action: String,
    val outcome: String,
    val code: String? = null,
)

enum class SyncActivityAction(val value: String) {
    LOCAL_SAVED("local_saved"), PROFILE_VALIDATION("profile_validation"), UPLOAD("upload"),
    CHECK_DELIVERY("check_delivery"), RESTORE("restore"), ERROR("error"),
}

enum class SyncActivityOutcome(val value: String) {
    STARTED("started"), SUCCEEDED("succeeded"), FAILED("failed"),
    WAITING_NETWORK("waiting_network"), WAITING_SERVER("waiting_server"), QUEUED("queued"),
}

/** Best-effort, app-private journal; not a durable work queue or a sync prerequisite.
 * Call only after an actual action/commit. record never waits for disk; pending writes
 * may be lost on process termination. recent performs a small disk read: use off UI thread.
 * All failures are contained here so logging cannot stop the real persistence/sync.
 */
object SyncActivityLog {
    internal const val PREFS = "sync_activity_log_v1"
    internal const val KEY = "events"
    const val MAX_EVENTS = 128
    internal const val MAX_JSON_CHARS = 65536
    private val lock = Any()
    // Bounded even if storage stalls; never run disk writes on the caller's thread.
    private val writer by lazy {
        ThreadPoolExecutor(1, 1, 30, TimeUnit.SECONDS, ArrayBlockingQueue<Runnable>(128),
            { task -> Thread(task, "sync-activity-log").apply { isDaemon = true } },
            ThreadPoolExecutor.DiscardPolicy()).apply { allowCoreThreadTimeOut(true) }
    }

    fun record(context: Context, kind: String, id: String, action: SyncActivityAction,
               outcome: SyncActivityOutcome, code: String? = null) {
        runCatching {
            val event = SyncActivityEvent(Instant.now().toString(), kind, id, action.value,
                outcome.value, safeCode(code))
            if (!isSafe(event)) return
            val app = context.applicationContext
            writer.execute { runCatching { append(app, event) } }
        }
    }

    fun recent(context: Context, kind: String, id: String, limit: Int = 20): List<SyncActivityEvent> =
        runCatching { synchronized(lock) {
            filterRecent(read(context), kind, id, limit)
        } }.getOrDefault(emptyList())

    private fun append(context: Context, event: SyncActivityEvent) = synchronized(lock) {
        val events = capped(read(context) + event)
        val array = JSONArray()
        events.forEach { item -> array.put(JSONObject().apply {
            put("timestampUtc", item.timestampUtc); put("entityKind", item.entityKind)
            put("entityId", item.entityId); put("action", item.action); put("outcome", item.outcome)
            item.code?.let { put("code", it) }
        }) }
        // commit is serialized on the background writer; failure is non-fatal.
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY, array.toString()).commit()
        Unit
    }

    private fun read(context: Context): List<SyncActivityEvent> = runCatching {
        decode(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null))
    }.getOrDefault(emptyList())

    internal fun decode(json: String?): List<SyncActivityEvent> {
        if (json == null || json.length > MAX_JSON_CHARS) return emptyList()
        return runCatching {
            val array = JSONArray(json)
            val events = mutableListOf<SyncActivityEvent>()
            // Examine bounded input, keeping each valid row if another row is damaged.
            for (i in 0 until array.length()) {
                val row = array.optJSONObject(i) ?: continue
                fun string(key: String): String? = row.opt(key) as? String
                val event = SyncActivityEvent(
                    string("timestampUtc") ?: continue, string("entityKind") ?: continue,
                    string("entityId") ?: continue, string("action") ?: continue,
                    string("outcome") ?: continue, safeCode(string("code")))
                if (isSafe(event)) events.add(event)
            }
            capped(events)
        }.getOrDefault(emptyList())
    }

    // A code is a fixed category, never a sanitized/truncated arbitrary error message.
    internal val allowedCodes = setOf(
        "offline", "server_disabled", "wifi_required", "network_error", "timeout", "cancelled",
        "validation_failed", "identity_conflict", "access_denied", "not_found", "integrity_error",
        "local_io", "server_error", "unknown_error", "http_400", "http_401", "http_403",
        "http_404", "http_408", "http_409", "http_413", "http_422", "http_429", "http_500",
        "http_502", "http_503", "http_504", "network_unavailable", "server_not_configured",
        "animal_id_already_exists", "profile_validation_failed", "upload_failed", "questionnaire_update_failed",
    )
    internal fun safeCode(code: String?): String? = code?.takeIf { it in allowedCodes }
    private val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    private val account = Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
    internal fun isSafe(event: SyncActivityEvent): Boolean =
        event.timestampUtc.length in 20..35 && runCatching { Instant.parse(event.timestampUtc) }.isSuccess &&
            when (event.entityKind) {
                "profile", "recording" -> uuid.matches(event.entityId)
                "account" -> account.matches(event.entityId)
                else -> false
            } && SyncActivityAction.entries.any { it.value == event.action } &&
            SyncActivityOutcome.entries.any { it.value == event.outcome } &&
            (event.code == null || event.code in allowedCodes)

    internal fun capped(events: List<SyncActivityEvent>): List<SyncActivityEvent> =
        events.filter(::isSafe).takeLast(MAX_EVENTS)

    internal fun filterRecent(events: List<SyncActivityEvent>, kind: String, id: String,
                              limit: Int = 20): List<SyncActivityEvent> =
        capped(events).asReversed().filter { it.entityKind == kind && it.entityId == id }
            .take(limit.coerceIn(0, MAX_EVENTS))
}
