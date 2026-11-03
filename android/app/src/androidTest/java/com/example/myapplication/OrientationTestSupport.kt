package com.example.myapplication

import android.app.Activity
import android.content.pm.ActivityInfo

/**
 * Deterministic orientation cleanup for UI tests.
 *
 * Restoring `SCREEN_ORIENTATION_UNSPECIFIED` does not re-apply the natural
 * orientation on a stationary physical device: after a test rotated the
 * activity to landscape, the display stayed landscape and the next test
 * (which then believed it started in landscape) failed in its own cleanup.
 * The test devices are portrait-natural, so an unspecified original is
 * restored as explicit portrait.
 */
internal fun Activity.restoreTestOrientation(original: Int) {
    requestedOrientation = if (original == ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED) {
        ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
    } else {
        original
    }
}
