package com.example.myapplication.sync

import com.example.myapplication.data.normalizeAccountId
import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.example.myapplication.BuildConfig
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class ServerSettings(
    val baseUrl: String,
    val token: String,
    val deviceId: String,
    val wifiOnly: Boolean,
    val accountId: String? = null,
) {
    val isConfigured: Boolean
        get() = baseUrl.isNotBlank() && token.isNotBlank()
}

// Serializes ownership and metadata edits with queued uploads.
internal val serverOperationLock = java.util.concurrent.locks.ReentrantLock()

enum class ServerSyncStatus {
    NOT_CONFIGURED,
    READY,
    WAITING,
    UPLOADING,
    NEEDS_ATTENTION,
}

data class ServerSyncUiState(
    val status: ServerSyncStatus = ServerSyncStatus.NOT_CONFIGURED,
    val baseUrl: String = BuildConfig.WOONA_SERVER_BASE_URL,
    val wifiOnly: Boolean = false,
    val pending: Int = 0,
    val uploading: Int = 0,
    val synced: Int = 0,
    val failed: Int = 0,
    val lastErrorMessage: String? = null,
    val restoring: Boolean = false,
    val mutationsAllowed: Boolean = true,
    val networkPolicyAllowed: Boolean = true,
    val mutationBlockReason: String? = null,
    val networkAvailable: Boolean? = null,
    val unmeteredNetwork: Boolean? = null,
    val workersRunning: Int = 0,
    val workersQueued: Int = 0,
    val connectionCheck: ConnectionCheck = ConnectionCheck.NOT_CHECKED,
    val checkedAtUtc: String? = null,
    val connectionError: String? = null,
    val operationMessage: String? = null,
    val accountId: String? = null,
) {
    val isConfigured: Boolean get() = status != ServerSyncStatus.NOT_CONFIGURED
}

class ServerSettingsStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    fun get(): ServerSettings = ServerSettings(
        baseUrl = preferences.getString(KEY_BASE_URL, DEFAULT_BASE_URL).orEmpty().trimEnd('/'),
        token = decrypt(preferences.getString(KEY_TOKEN, null)) ?: DEFAULT_TOKEN,
        deviceId = preferences.getString(KEY_DEVICE_ID, null)
            ?: UUID.randomUUID().toString().also {
                preferences.edit().putString(KEY_DEVICE_ID, it).apply()
            },
        wifiOnly = preferences.getBoolean(KEY_WIFI_ONLY, false),
        accountId = preferences.getString("account_id", null),
    )

    fun save(baseUrl: String, token: String, wifiOnly: Boolean) {
        val normalizedUrl = baseUrl.trim().trimEnd('/')
        require(normalizedUrl.startsWith("https://") || normalizedUrl.startsWith("http://10.0.2.2")) {
            "Use HTTPS, or http://10.0.2.2 for the local emulator"
        }
        require(token.isNotBlank()) { "Server token is required" }
        preferences.edit()
            .putString(KEY_BASE_URL, normalizedUrl)
            .putString(KEY_TOKEN, encrypt(token.trim()))
            .putBoolean(KEY_WIFI_ONLY, wifiOnly)
            .apply()
    }

    fun setAccount(identifier: String?) {
        preferences.edit().putString("account_id", identifier?.let(::normalizeAccountId)).commit()
    }

    fun setWifiOnly(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_WIFI_ONLY, enabled).apply()
    }

    fun clearToken() {
        preferences.edit().remove(KEY_TOKEN).apply()
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        return listOf(cipher.iv, cipher.doFinal(value.toByteArray(Charsets.UTF_8)))
            .joinToString(".") { Base64.encodeToString(it, Base64.NO_WRAP) }
    }

    private fun decrypt(value: String?): String? {
        if (value == null) return null
        return runCatching {
            val (iv, encrypted) = value.split('.', limit = 2).map {
                Base64.decode(it, Base64.NO_WRAP)
            }
            Cipher.getInstance(TRANSFORMATION).run {
                init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
                String(doFinal(encrypted), Charsets.UTF_8)
            }
        }.getOrNull()
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
            generateKey()
        }
    }

    companion object {
        val DEFAULT_BASE_URL: String = BuildConfig.WOONA_SERVER_BASE_URL
        val DEFAULT_TOKEN: String = BuildConfig.WOONA_SERVER_TOKEN
        private const val PREFERENCES_NAME = "woona_server"
        private const val KEY_BASE_URL = "base_url"
        private const val KEY_TOKEN = "encrypted_token"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_WIFI_ONLY = "wifi_only"
        private const val KEY_ALIAS = "woona_server_token_v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
