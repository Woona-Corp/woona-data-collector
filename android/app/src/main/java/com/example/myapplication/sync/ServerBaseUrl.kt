package com.example.myapplication.sync

import java.net.URI

private const val INVALID_SERVER_URL = "Server URL is invalid. Use a complete HTTPS URL with a valid host and port, without username/password, query or fragment. HTTP is allowed only for localhost, 127.0.0.1, [::1] or 10.0.2.2."

/** Validate the destination before persisting settings or handling a token. */
internal fun normalizedServerBaseUrl(input: String): String {
    val value = input.trim().trimEnd('/')
    require(value.none { it.isWhitespace() || it.isISOControl() || it == '\\' }) { INVALID_SERVER_URL }
    val uri = runCatching { URI(value).parseServerAuthority() }.getOrNull()
    require(uri != null && !uri.isOpaque && !uri.host.isNullOrBlank()) { INVALID_SERVER_URL }
    require(uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null) { INVALID_SERVER_URL }
    require(uri.port == -1 || uri.port in 1..65535) { INVALID_SERVER_URL }
    require(uri.rawAuthority?.endsWith(':') != true) { INVALID_SERVER_URL }
    val host = uri.host.lowercase().removeSurrounding("[", "]")
    require(!host.contains('%') && host.length <= 253 && (host.contains(':') || host.trimEnd('.').split('.').all { it.length in 1..63 })) { INVALID_SERVER_URL }
    val scheme = uri.scheme?.lowercase()
    require(scheme == "https" || (scheme == "http" && host in setOf("10.0.2.2", "localhost", "127.0.0.1", "::1"))) { INVALID_SERVER_URL }
    return value
}
