package com.example.myapplication.data

import android.content.Context
import androidx.annotation.VisibleForTesting

/**
 * The capture controller can outlive an Activity, and cancelled Activity work
 * can still be inside a blocking SQLite call. Keep their helper open for the
 * process lifetime instead of closing it underneath an in-flight transaction.
 * Short-lived workers and isolated database roots continue to own their helpers.
 */
internal object ActivityDatabase {
    private var instance: WoonaDatabase? = null

    @Synchronized
    fun get(context: Context): WoonaDatabase = instance ?: WoonaDatabase(context.applicationContext).also { instance = it }

    /** Only for isolated instrumentation fixtures after all Activities have stopped. */
    @VisibleForTesting
    @Synchronized
    fun resetForTesting() {
        instance?.close()
        instance = null
    }
}
