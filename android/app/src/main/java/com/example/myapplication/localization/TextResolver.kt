package com.example.myapplication.localization

import androidx.annotation.StringRes
import com.example.myapplication.R
import java.util.Locale

interface TextResolver {
    fun getString(@StringRes resId: Int, vararg formatArgs: Any): String
}

object EnglishTextResolver : TextResolver {
    override fun getString(
        @StringRes resId: Int,
        vararg formatArgs: Any,
    ): String {
        val template = when (resId) {
            R.string.permissions_required -> "Bluetooth permission is required to find and connect to sensors. Allow Nearby devices in Android Settings, then retry the search."
            R.string.replay_file_empty -> "Replay file is empty"
            R.string.replay_file_invalid -> "Replay file is not a valid packet dump"
            R.string.replay_interrupted -> "Replay interrupted"
            R.string.replay_failed -> "Replay failed"
            R.string.replay_unavailable -> "Replay is unavailable"
            R.string.share_file_failed -> "Failed to share file"
            R.string.export_prepare_failed -> "Failed to prepare session archive"
            R.string.transport_profile_selected_next_connection ->
                "BLE transport profile selected: %1\$s. Changes apply on the next connection."

            R.string.failed_persist_raw_fragment -> "Failed to persist raw BLE fragment"
            R.string.failed_reset_capture_session -> "Failed to reset capture session"
            R.string.failed_flush_buffered_output -> "Failed to flush buffered output"
            R.string.interrupted_waiting_packet_processor_shutdown ->
                "Interrupted while waiting for packet processor shutdown"
            R.string.failed_close_buffered_output -> "Failed to close buffered output"
            R.string.background_packet_processing_failed -> "Background packet processing failed"
            R.string.failed_append_validated_packet -> "Failed to append validated packet to output file"
            R.string.failed_persist_diagnostic_log_event -> "Failed to persist diagnostic log event"
            R.string.capture_queue_overflow -> "Capture queue overflow: dropped=%1\$d, depth=%2\$d/%3\$d, fragmentBytes=%4\$d"
            R.string.capture_queue_pressure ->
                "Capture queue pressure: depth=%1\$d/%2\$d (%3\$d%%), maxDepth=%4\$d, fragmentBytes=%5\$d"
            R.string.capture_summary ->
                "Capture summary: packets=%1\$d, lost=%2\$d, rejected=%3\$d, timerRegressionRejects=%4\$d, fragmentsReceived=%5\$d, fragmentsPersisted=%6\$d, rawBytes=%7\$d, dropped=%8\$d, queueDepthCurrent=%9\$d, queueDepthMax=%10\$d"
            R.string.accepted_packet_message -> "Accepted packet counter=%1\$d, timer=%2\$d, len=%3\$d, meas=%4\$d"
            R.string.gap_detected_message -> "Gap detected: expected=%1\$s, actual=%2\$s, missing=%3\$d"
            R.string.rejected_packet_message -> "Rejected packet: %1\$s"
            R.string.rejected_packet_detail_reason -> "reason=%1\$s"
            R.string.rejected_packet_detail_length -> "len=%1\$d"
            R.string.rejected_packet_detail_counter -> "counter=%1\$d"
            R.string.rejected_packet_detail_timer -> "timer=%1\$d"
            R.string.packet_timer_regressed -> "Packet timer regressed"
            R.string.failed_write_accepted_packet -> "Failed to write accepted packet"
            R.string.rejection_breakdown_item -> "%1\$s: %2\$d"
            R.string.packet_assembly_overlapping_start ->
                "New packet start marker found before previous packet completed"
            R.string.packet_validation_invalid_start -> "Invalid packet start marker"
            R.string.packet_validation_invalid_length -> "Invalid packet length"
            R.string.packet_validation_invalid_measurement_count -> "Invalid measurement count"
            R.string.packet_validation_invalid_sensor_blocks -> "Invalid sensor block layout"
            R.string.transport_profile_default -> "Maximum performance"
            R.string.transport_profile_compatibility -> "Compatibility"
            R.string.transport_profile_conservative -> "Conservative"
            else -> "res-$resId"
        }
        return if (formatArgs.isEmpty()) {
            template
        } else {
            String.format(Locale.US, template, *formatArgs)
        }
    }
}
