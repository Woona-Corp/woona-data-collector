package com.example.myapplication.sync

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel

/** Sensitive editing state: memory only, deliberately no SavedStateHandle/saver. */
class ServerConnectionDraft(initialUrl: String) {
    var baseUrl by mutableStateOf(initialUrl)
    var token by mutableStateOf("")
    fun clear() { baseUrl = ""; token = "" }
}

class ServerSettingsDraftViewModel : ViewModel() {
    private var draft: ServerConnectionDraft? = null
    fun open(currentUrl: String): ServerConnectionDraft = draft ?: ServerConnectionDraft(currentUrl).also { draft = it }
    fun dismiss() { draft?.clear(); draft = null }
    override fun onCleared() { dismiss() }
}
