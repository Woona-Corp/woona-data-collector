package com.example.myapplication.sync

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.example.myapplication.data.Artifact
import com.example.myapplication.data.ArtifactType
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.preferredDiagnosticArtifact
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class CaptureDiagnosticDetailsTest {
    @get:Rule val compose = createComposeRule()

    @Test fun openDetailsReloadWhenDiagnosticBecomesLocalWithoutRereadingUnchangedKey() {
        var refreshKey by mutableStateOf("remote" to "diagnostics.log")
        var unrelatedState by mutableIntStateOf(0)
        var content = "before download"
        var loads = 0
        compose.setContent {
            unrelatedState
            MaterialTheme {
                CaptureDiagnosticDetails(
                    recordingId = "recording",
                    language = AppLanguage.ENGLISH,
                    refreshKey = refreshKey,
                ) {
                    loads++
                    content
                }
            }
        }

        compose.onNodeWithText("+ Capture log").performClick()
        compose.waitUntil(5_000) { loads == 1 }
        compose.onNodeWithText("before download").assertExists()

        compose.runOnIdle { unrelatedState++ }
        compose.runOnIdle { assertEquals(1, loads) }

        compose.runOnIdle {
            content = "after download"
            refreshKey = "local" to "diagnostics.log"
        }
        compose.waitUntil(5_000) { loads == 2 }
        compose.onNodeWithText("after download").assertExists()
        compose.runOnIdle { assertEquals(2, loads) }
    }

    @Test fun laterLocalDiagnosticIsReadWhenRemoteOnlyDiagnosticComesFirst() {
        val artifacts = listOf(
            diagnosticArtifact("remote", "remote_only"),
            diagnosticArtifact("local", "local"),
        )
        var loads = 0
        compose.setContent {
            MaterialTheme {
                val diagnosticArtifact = preferredDiagnosticArtifact(artifacts)
                CaptureDiagnosticDetails(
                    recordingId = "recording",
                    language = AppLanguage.ENGLISH,
                    refreshKey = diagnosticArtifact?.let { it.localPresence to it.relativePath },
                ) {
                    loads++
                    diagnosticArtifact
                        ?.takeIf { it.localPresence in setOf("local", "both") }
                        ?.let { "local diagnostic contents" }
                }
            }
        }

        compose.onNodeWithText("+ Capture log").performClick()
        compose.waitUntil(5_000) { loads == 1 }
        compose.onNodeWithText("local diagnostic contents").assertExists()
        compose.runOnIdle { assertEquals("local", preferredDiagnosticArtifact(artifacts)?.id) }
    }

    private fun diagnosticArtifact(id: String, localPresence: String) = Artifact(
        id = id,
        recordingId = "recording",
        type = ArtifactType.DIAGNOSTIC,
        fileName = "diagnostics.log",
        mimeType = "text/plain",
        relativePath = "$id-diagnostics.log",
        sizeBytes = 1,
        sha256 = id,
        localPresence = localPresence,
        uploadState = "available",
        uploadedBytes = 1,
        createdAtUtc = "2026-11-12T00:00:00Z",
    )
}
