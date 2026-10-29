package com.example.myapplication

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.example.myapplication.data.*
import com.example.myapplication.feature.device.VideoCaptureState
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.profile.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RecordingHistoryUiTest {
    @get:Rule val compose=createComposeRule()
    @Test fun thousandRowsAreVirtualizedAndLastRecordRemainsReachable() {
        val rows=(0 until 1205).map(::recording)
        compose.setContent { MaterialTheme { ProfilesOverview(emptyList(),null,rows,AppLanguage.ENGLISH,{},{},{},{},videoState=VideoCaptureState.IDLE,videoOffsetMillis=null,onVideoAction={},section=ProfileScreenSection.RECORDINGS,showingAllRecordings=true,recordingsTotal=1205) } }
        compose.onNodeWithText("Shown 1205 of 1205").assertIsDisplayed()
        val rowText=SemanticsMatcher("capture status") { node -> node.config.getOrElse(SemanticsProperties.Text) { emptyList() }.any {it.text.startsWith("Capture:")} }
        assertTrue("Lazy history must not compose 1205 cards",compose.onAllNodes(rowText).fetchSemanticsNodes().size<20)
        compose.onNodeWithTag("recordings.history").performScrollToIndex(1205)
        compose.onNodeWithText("Session 1204",substring=true).assertExists()
        assertTrue(compose.onAllNodes(rowText).fetchSemanticsNodes().size<20)
    }
    @Test fun moreActionUsesActualRemainingCount() {
        var requested=0
        var refreshes=0
        compose.setContent { MaterialTheme { ProfilesOverview(emptyList(),null,(0 until 100).map(::recording),AppLanguage.ENGLISH,{},{},{},{},videoState=VideoCaptureState.IDLE,videoOffsetMillis=null,onVideoAction={},section=ProfileScreenSection.RECORDINGS,showingAllRecordings=true,recordingsTotal=130,onShowMoreRecordings={requested++},onRefreshRecordings={refreshes++}) } }
        compose.onNodeWithText("Refresh history").performClick()
        compose.runOnIdle { assertEquals(1,refreshes) }
        compose.onNodeWithTag("recordings.history").performScrollToIndex(101)
        compose.onNodeWithText("Show 30 more").performClick()
        compose.runOnIdle { assertEquals(1,requested) }
    }
    @Test fun deletedRemainingRowsOfferExplicitRefreshWithoutANonfunctionalMoreAction() {
        compose.setContent { MaterialTheme { ProfilesOverview(emptyList(),null,(0 until 100).map(::recording),AppLanguage.ENGLISH,{},{},{},{},videoState=VideoCaptureState.IDLE,videoOffsetMillis=null,onVideoAction={},section=ProfileScreenSection.RECORDINGS,showingAllRecordings=true,recordingsTotal=105,historyHasMoreRecordings=false) } }
        compose.onNodeWithTag("recordings.history").performScrollToIndex(101)
        compose.onNodeWithText("History changed while you were viewing it. Refresh to recount recordings.").assertExists()
        compose.onNodeWithText("Show 5 more").assertDoesNotExist()
    }
    @Test fun quotaExplanationKeepsSelectableOriginalRequestDetails() {
        val row=recording(0).copy(serverSyncState="permanent_error",serverSyncError="HTTP 413 storage_quota_exceeded requestId=fixture-id")
        compose.setContent { MaterialTheme { ProfilesOverview(emptyList(),null,listOf(row),AppLanguage.ENGLISH,{},{},{},{},videoState=VideoCaptureState.IDLE,videoOffsetMillis=null,onVideoAction={},section=ProfileScreenSection.RECORDINGS) } }
        compose.onNodeWithText("storage limit",substring=true).assertExists()
        compose.onNodeWithText("Error details").performScrollTo().performClick()
        compose.onNodeWithText("requestId=fixture-id",substring=true).assertExists()
    }
    private fun recording(index:Int)=Recording("id-$index","dog","profile",RecordingSource.LIVE,RecordingStatus.COMPLETED,"Session $index",false,"2026-07-01T10:00:00Z",null,"UTC",null,"recordings/dog/$index")
}
