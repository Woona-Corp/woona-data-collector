package com.example.myapplication.sync

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performClick
import com.example.myapplication.localization.AppLanguage
import org.junit.Rule
import org.junit.Test
import org.junit.Assert.assertEquals

class ServerSettingsDialogTest {
    @get:Rule val compose=createComposeRule()
    @Test fun disconnectRemainsAvailableDuringUploadAndRequiresExplicitConfirmation() {
        var saved=0;var disconnected=0
        compose.setContent { MaterialTheme {
            ServerSettingsDialog(ServerSettings("https://invalid.example","synthetic","device",true),AppLanguage.ENGLISH,
                onDismiss={},onSave={_,_->saved++},onDisconnect={disconnected++},canSave=false,canDisconnect=true)
        } }
        compose.onNodeWithText("Save").assertIsNotEnabled()
        compose.onNodeWithText("Disconnect server and remove token").assertIsEnabled().performClick()
        assertEquals(0,disconnected)
        compose.onAllNodesWithText("Cancel").onLast().performClick()
        assertEquals(0,disconnected)
        compose.onNodeWithText("Disconnect server and remove token").performClick()
        compose.onNodeWithText("Disconnect").performClick()
        compose.runOnIdle {assertEquals(1,disconnected);assertEquals(0,saved)}
    }
}
