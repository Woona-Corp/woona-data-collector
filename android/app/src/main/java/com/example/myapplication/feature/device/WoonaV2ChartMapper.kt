package com.example.myapplication.feature.device

import com.example.myapplication.protocol.WoonaV2LiveSession

/**
 * Converts already validated V2 sample blocks into *preview* chart points.
 * No Legacy packet is synthesized; this mapper must never be used as a persistence format.
 * Device timestamps and the DATA block's actual output rate define the X axis.
 */
object WoonaV2ChartMapper {
    const val MAX_PREVIEW_INSTANTS_PER_BLOCK = 128
    private const val MICROS_PER_SECOND = 1_000_000L

    fun map(event: WoonaV2LiveSession.Event.Samples): Map<ChartStreamKey, List<ChartPoint>> {
        val block = event.block
        val descriptor = event.descriptor
        if (block.count <= 0 || block.rateHz <= 0 || block.timestampUs < 0 ||
            block.streamId != descriptor.id ||
            descriptor.channels !in 1..3 || descriptor.format !in 1..2 ||
            block.samples.size.toLong() != block.count.toLong() * descriptor.channels * 2L ||
            block.flags and 1 == 0
        ) return emptyMap() // Do not invent timestamps when the firmware marks them invalid.
        val sensorType = when (block.streamId) {
            1 -> 2 // accel
            2 -> 3 // gyro
            3 -> 4 // contact microphone
            4 -> 5 // ambient microphone (V2-only selector)
            5 -> 6 // piezo (V2-only selector)
            6 -> 7 // main-board temperature, raw S16 preview units
            7 -> 8 // ribbon temperature, raw S16 preview units
            else -> return emptyMap()
        }
        if (block.streamId in 6..7 && (descriptor.format != 1 || descriptor.channels != 1)) return emptyMap()
        val gap = event.sequenceGap || (block.flags and 2 != 0)
        val step = ((block.count + MAX_PREVIEW_INSTANTS_PER_BLOCK - 1) /
            MAX_PREVIEW_INSTANTS_PER_BLOCK).coerceAtLeast(1)
        val result = linkedMapOf<ChartStreamKey, MutableList<ChartPoint>>()
        for (channel in 0 until descriptor.channels) {
            val samples = result.getOrPut(ChartStreamKey(sensorType, channel + 1)) { mutableListOf() }
            for (sampleIndex in 0 until block.count step step) {
                val offset = (sampleIndex * descriptor.channels + channel) * 2
                val raw = (block.samples[offset].toInt() and 255) or
                    ((block.samples[offset + 1].toInt() and 255) shl 8)
                val value = if (descriptor.format == 1) raw.toShort().toFloat() else raw.toFloat()
                val timeMicros = block.timestampUs + sampleIndex.toLong() * MICROS_PER_SECOND / block.rateHz
                if (timeMicros < block.timestampUs) return emptyMap() // Overflow safeguard.
                samples += ChartPoint(
                    timeMillis = timeMicros / 1000L,
                    value = value,
                    startsNewSegment = gap && sampleIndex == 0,
                )
            }
        }
        return result
    }
}

/** UI timing guard; accepted wire blocks are still counted before this stage. */
class V2PreviewTimeline {
    private val lastEndUs = LongArray(8) { -1 }
    private val pendingBreak = BooleanArray(8)
    fun reset() { lastEndUs.fill(-1); pendingBreak.fill(false) }
    fun map(event: WoonaV2LiveSession.Event.Samples): Map<ChartStreamKey, List<ChartPoint>> {
        val id = event.block.streamId
        if (id !in 1..7) return emptyMap()
        val block = event.block
        if (lastEndUs[id] >= 0 && block.timestampUs <= lastEndUs[id]) {
            pendingBreak[id] = true
            return emptyMap()
        }
        val mapped = WoonaV2ChartMapper.map(event.copy(sequenceGap = event.sequenceGap || pendingBreak[id]))
        if (mapped.isEmpty()) { pendingBreak[id] = true; return mapped }
        val duration = (block.count - 1).toLong() * 1_000_000L / block.rateHz
        if (duration > Long.MAX_VALUE - block.timestampUs) { pendingBreak[id] = true; return emptyMap() }
        lastEndUs[id] = block.timestampUs + duration
        pendingBreak[id] = false
        return mapped
    }
}
