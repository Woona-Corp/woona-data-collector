package com.example.myapplication.sync

import com.example.myapplication.data.SYNC_GAP_PROFILE_MISSING
import com.example.myapplication.data.SYNC_GAP_RECORDING_MISSING
import com.example.myapplication.data.SYNC_GAP_SYNC_MISSING
import com.example.myapplication.data.SyncGapOutcome
import com.example.myapplication.data.syncGapOutcome
import org.junit.Assert.assertEquals
import org.junit.Test

class SyncGapOutcomeTest {
    // A deleted recording really is finished. A missing recording_sync or profile
    // row is a write failure, and reporting success for it hides the loss.
    @Test
    fun onlyALocallyRemovedRecordingCountsAsFinished() {
        assertEquals(SyncGapOutcome.REMOVED_LOCALLY, syncGapOutcome(SYNC_GAP_RECORDING_MISSING))
    }

    @Test
    fun missingRowsAreReportedInsteadOfSilentlySucceeding() {
        for (gap in listOf(SYNC_GAP_SYNC_MISSING, SYNC_GAP_PROFILE_MISSING, null, "unexpected")) {
            assertEquals("gap=$gap", SyncGapOutcome.MISSING_METADATA, syncGapOutcome(gap))
        }
    }
}
