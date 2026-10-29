package com.example.myapplication.sync

import com.example.myapplication.localization.AppLanguage
import org.json.JSONObject
import java.util.Locale

/** Volume/admission metrics, never a statement about SHA or receipt verification. */
data class ServerStorageStatus(
    val accountId: String?,
    val recordingLimitBytes: Long,
    val accountLimitBytes: Long,
    val declaredReservedBytes: Long,
    val acknowledgedBytes: Long,
    val remainingQuotaBytes: Long?,
    val recordings: Long,
    val artifacts: Long,
    val serverTotalBytes: Long,
    val serverFreeBytes: Long,
    val freeSpaceReserveBytes: Long,
    val pendingReservedBytes: Long,
    val pendingArtifacts: Long,
    val newReservationAvailableBytes: Long,
    val status: String,
    val nextAction: String,
    val blockingReasons: List<String>,
    val existingUploadsMayResume: Boolean,
)

enum class StorageCheck { NOT_CHECKED, CHECKING, CHECKED, UNAVAILABLE, FAILED }
data class ServerStorageUiState(
    val check: StorageCheck = StorageCheck.NOT_CHECKED,
    val checkedAtUtc: String? = null,
    val result: ServerStorageStatus? = null,
    val error: String? = null,
)

/** Fences callbacks after URL, token, account, or transfer-generation changes. */
internal class StorageRequestEpoch {
    private var configuration: ServerSettings? = null
    private var epoch = 0L
    @Synchronized fun configure(settings: ServerSettings): Boolean {
        if (configuration == settings) return false
        configuration = settings; epoch++
        return true
    }
    @Synchronized fun begin(settings: ServerSettings): Long { configure(settings); return ++epoch }
    @Synchronized fun accepts(ticket: Long, settings: ServerSettings): Boolean = epoch == ticket && configuration == settings
}

internal fun parseServerStorageStatus(value: JSONObject, requestedAccountId: String?): ServerStorageStatus {
    val scope = value.getJSONObject("checkedScope")
    val accountId = if (scope.isNull("accountId")) null else scope.getString("accountId")
    if (accountId != requestedAccountId || scope.getBoolean("unassignedOnly") != (requestedAccountId == null) || scope.getBoolean("includesAllAccounts")) {
        throw ServerTransferException("storage_scope_mismatch", "Storage response belongs to a different account scope; retry this check")
    }
    val limits = value.getJSONObject("limits")
    val account = value.getJSONObject("account")
    val server = value.getJSONObject("serverStorage")
    require(server.getString("scope") == "server") { "Storage response is missing the server-wide scope" }
    fun bytes(obj: JSONObject, key: String): Long {
        val raw=obj.get(key)
        val integer=when(raw) {
            is Byte -> raw.toLong()
            is Short -> raw.toLong()
            is Int -> raw.toLong()
            is Long -> raw
            else -> throw IllegalArgumentException("Invalid storage metric: $key; expected a signed 64-bit JSON integer")
        }
        return integer.also { require(it >= 0) { "Invalid storage metric: $key; expected nonnegative bytes" } }
    }
    val reasons = value.getJSONObject("admission").getJSONArray("blockingReasons")
    return ServerStorageStatus(accountId,
        bytes(limits,"recordingBytes"), bytes(limits,"accountBytes"),
        bytes(account,"declaredReservedBytes"), bytes(account,"acknowledgedBytes"),
        if (account.get("remainingQuotaBytes") == JSONObject.NULL) null else bytes(account,"remainingQuotaBytes"),
        bytes(account,"recordings"), bytes(account,"artifacts"),
        bytes(server,"totalBytes"), bytes(server,"freeBytes"), bytes(server,"freeSpaceReserveBytes"),
        bytes(server,"pendingReservedBytes"), bytes(server,"pendingArtifacts"), bytes(server,"newReservationAvailableBytes"),
        value.getString("status"), value.getString("nextAction"),
        (0 until reasons.length()).map { reasons.getString(it) }, value.getBoolean("existingUploadsMayResume"))
}

fun storageGiB(bytes: Long?, language: AppLanguage, limit: Boolean = false): String {
    if (bytes == null || (limit && bytes == 0L)) return if (language == AppLanguage.RUSSIAN) "Без ограничений" else "Unlimited"
    return String.format(if (language == AppLanguage.RUSSIAN) Locale.forLanguageTag("ru-RU") else Locale.US, "%.2f %s", bytes / 1073741824.0, if (language == AppLanguage.RUSSIAN) "ГиБ" else "GiB")
}

fun storageAdmissionText(status: String, language: AppLanguage): String = when (status) {
    "ready" -> if (language == AppLanguage.RUSSIAN) "Место для новых загрузок доступно" else "Storage is available for new uploads"
    "capacity_reserved", "server_capacity_reserved" -> if (language == AppLanguage.RUSSIAN) "Место зарезервировано другими загрузками" else "Capacity is reserved by other uploads"
    "account_quota_reached" -> if (language == AppLanguage.RUSSIAN) "Лимит хранения аккаунта исчерпан" else "Account storage limit reached"
    else -> status
}
