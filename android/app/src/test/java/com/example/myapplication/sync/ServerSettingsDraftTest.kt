package com.example.myapplication.sync

import org.junit.Assert.*
import org.junit.Test

class ServerSettingsDraftTest {
    @Test fun retainedOwnerKeepsDraftButDismissAndNewOwnerDoNot() {
        val owner = ServerSettingsDraftViewModel()
        val draft = owner.open("https://saved.invalid")
        draft.baseUrl = "https://draft.invalid"
        draft.token = "synthetic-draft-only"
        assertSame(draft, owner.open("https://saved.invalid"))
        assertEquals("synthetic-draft-only", owner.open("https://saved.invalid").token)
        owner.dismiss()
        assertEquals("", draft.token)
        assertEquals("https://saved.invalid", owner.open("https://saved.invalid").baseUrl)
        assertEquals("", owner.open("https://saved.invalid").token)
        assertEquals("", ServerSettingsDraftViewModel().open("https://saved.invalid").token)
    }
}
