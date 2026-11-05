import Foundation

struct SessionChart {
    private(set) var selectedSensorType = 2
    private(set) var selectedChannel = 1
    private(set) var chart = ChartUiState()
    private var chartHistory: [ChartStreamKey: [ChartPoint]] = [:]
    private var sessionStartMillis: UInt64?
    private var latestChartTimeMillis: UInt64?
    private var chartWindowPreset: ChartWindowPreset = .thirtySeconds
    private var isFollowingLive = true
    private var manualViewportEndMillis: UInt64?
    private var chartVerticalZoomFactor: Float = 1
    private var chartVerticalCenterOverride: Float?

    mutating func replaceHistory(_ history: [ChartStreamKey: [ChartPoint]]) {
        chartHistory = history
        sessionStartMillis = history.values.compactMap { $0.first?.timeMillis }.min()
        latestChartTimeMillis = history.values.compactMap { $0.last?.timeMillis }.max()
        trimChartHistory()
        rebuildChartState()
    }

    mutating func selectSensorType(_ sensorType: Int) {
        selectedSensorType = sensorType
        selectedChannel = 1
        chartVerticalCenterOverride = nil
        rebuildChartState()
    }

    mutating func selectChannel(_ channel: Int) {
        selectedChannel = channel
        chartVerticalCenterOverride = nil
        rebuildChartState()
    }

    mutating func selectChartWindow(_ preset: ChartWindowPreset) {
        chartWindowPreset = preset
        chartVerticalCenterOverride = nil
        rebuildChartState()
    }

    mutating func setFollowLive(_ enabled: Bool) {
        isFollowingLive = enabled
        manualViewportEndMillis = enabled ? nil : latestChartTimeMillis
        chartVerticalCenterOverride = nil
        rebuildChartState()
    }

    mutating func jumpToLive() {
        setFollowLive(true)
    }

    mutating func panChartLeft() {
        guard let latest = latestChartTimeMillis, let sessionStartMillis else { return }
        let currentEnd = resolveViewportEnd(latest: latest)
        let duration = effectiveViewportDurationMillis(viewportEnd: currentEnd)
        guard duration > 0 else { return }
        let minViewportEnd = min(sessionStartMillis + duration, latest)
        let panStep = chartPanStepMillis(viewportEnd: currentEnd)
        let shiftedEnd = currentEnd > panStep ? currentEnd - panStep : 0
        chartVerticalCenterOverride = nil
        isFollowingLive = false
        manualViewportEndMillis = max(shiftedEnd, minViewportEnd)
        rebuildChartState()
    }

    mutating func panChartRight() {
        guard let latest = latestChartTimeMillis else { return }
        let currentEnd = resolveViewportEnd(latest: latest)
        let shiftedEnd = min(currentEnd + chartPanStepMillis(viewportEnd: currentEnd), latest)
        chartVerticalCenterOverride = nil
        isFollowingLive = shiftedEnd >= latest
        manualViewportEndMillis = isFollowingLive ? nil : shiftedEnd
        rebuildChartState()
    }

    mutating func panChart(byFraction deltaFraction: Double) {
        guard
            let latest = latestChartTimeMillis
        else { return }
        let viewportEnd = resolveViewportEnd(latest: latest)

        let duration = effectiveViewportDurationMillis(viewportEnd: viewportEnd)
        guard duration > 0 else { return }
        let deltaMillis = Int64(Double(duration) * deltaFraction)
        guard deltaMillis != 0, let sessionStartMillis else { return }

        let minViewportEnd = min(sessionStartMillis + duration, latest)
        let shiftedEnd: UInt64
        if deltaMillis < 0 {
            shiftedEnd = viewportEnd > UInt64(abs(deltaMillis)) ? viewportEnd - UInt64(abs(deltaMillis)) : 0
        } else {
            shiftedEnd = viewportEnd + UInt64(deltaMillis)
        }

        chartVerticalCenterOverride = nil
        let clampedEnd = min(max(shiftedEnd, minViewportEnd), latest)
        isFollowingLive = clampedEnd >= latest
        manualViewportEndMillis = isFollowingLive ? nil : clampedEnd
        rebuildChartState()
    }

    mutating func zoomChart(scaleFactor: Float, anchorFractionY: Float = 0.5) {
        guard scaleFactor > 0 else { return }
        let currentRange = chart.yAxisAbsRange
        let currentCenter = chart.yAxisCenter
        let nextZoomFactor = min(max(chartVerticalZoomFactor * scaleFactor, 1), 64)
        guard nextZoomFactor != chartVerticalZoomFactor else { return }

        let nextRange = chartYAxisAbsRange(zoomFactor: nextZoomFactor)
        chartVerticalZoomFactor = nextZoomFactor
        if nextZoomFactor == 1 {
            chartVerticalCenterOverride = nil
        } else {
            let clampedAnchor = min(max(anchorFractionY, 0), 1)
            let anchorCoefficient = 1 - (2 * clampedAnchor)
            chartVerticalCenterOverride = currentCenter + ((currentRange - nextRange) * anchorCoefficient)
        }
        rebuildChartState()
    }

    mutating func zoomChartIn() {
        zoomChart(scaleFactor: 2)
    }

    mutating func zoomChartOut() {
        zoomChart(scaleFactor: 0.5)
    }

    mutating func resetChartY() {
        chartVerticalZoomFactor = 1
        chartVerticalCenterOverride = nil
        rebuildChartState()
    }

    mutating func appendChartSamples(_ samplesByStream: [ChartStreamKey: [ChartPoint]]) {
        guard !samplesByStream.isEmpty else { return }

        for (streamKey, points) in samplesByStream where !points.isEmpty {
            chartHistory[streamKey, default: []].append(contentsOf: points)

            if let first = points.first?.timeMillis {
                sessionStartMillis = min(sessionStartMillis ?? first, first)
            }
            if let last = points.last?.timeMillis {
                latestChartTimeMillis = max(latestChartTimeMillis ?? last, last)
            }
        }

        trimChartHistory()
        rebuildChartState()
    }

    mutating func clearChartHistory() {
        chartHistory.removeAll(keepingCapacity: true)
        sessionStartMillis = nil
        latestChartTimeMillis = nil
        chartWindowPreset = .thirtySeconds
        isFollowingLive = true
        manualViewportEndMillis = nil
        chartVerticalZoomFactor = 1
        chartVerticalCenterOverride = nil
        chart = ChartUiState()
    }

    private mutating func trimChartHistory() {
        guard let latestChartTimeMillis else { return }
        let cutoff = latestChartTimeMillis > Self.maxRetainedHistoryMillis
            ? latestChartTimeMillis - Self.maxRetainedHistoryMillis
            : 0

        for key in Array(chartHistory.keys) {
            guard let firstPoint = chartHistory[key]?.first, firstPoint.timeMillis < cutoff else { continue }
            guard let firstRetainedIndex = chartHistory[key]?.firstIndex(where: { $0.timeMillis >= cutoff }) else {
                chartHistory.removeValue(forKey: key)
                continue
            }
            if firstRetainedIndex > 0 {
                chartHistory[key]?.removeSubrange(0..<firstRetainedIndex)
            }
        }

        sessionStartMillis = chartHistory.values.compactMap(\.first?.timeMillis).min()
        self.latestChartTimeMillis = chartHistory.values.compactMap(\.last?.timeMillis).max()
        if !isFollowingLive {
            manualViewportEndMillis = manualViewportEndMillis.map { max($0, sessionStartMillis ?? $0) }
        }
    }

    private mutating func rebuildChartState() {
        let sessionStart = sessionStartMillis
        let latest = latestChartTimeMillis
        let viewportEnd = latest.map { resolveViewportEnd(latest: $0) }
        let viewportDuration = viewportEnd.map(effectiveViewportDurationMillis) ?? chartWindowPreset.durationMillis
        let viewportStart: UInt64?
        if let viewportEnd {
            viewportStart = max(sessionStart ?? viewportEnd, viewportEnd > viewportDuration ? viewportEnd - viewportDuration : 0)
        } else {
            viewportStart = nil
        }

        let streamPoints = chartHistory[ChartStreamKey(sensorType: selectedSensorType, channel: selectedChannel)] ?? []
        let visiblePoints: [ChartPoint]
        if let viewportStart, let viewportEnd {
            visiblePoints = downsampleVisiblePoints(
                Array(slicePoints(streamPoints, startMillis: viewportStart, endMillis: viewportEnd)),
                maxPoints: Self.maxRenderedChartPoints
            )
        } else {
            visiblePoints = []
        }

        chart = ChartUiState(
            points: visiblePoints,
            windowPreset: chartWindowPreset,
            isFollowingLive: isFollowingLive,
            canPanLeft: viewportStart != nil && sessionStart != nil && viewportStart! > sessionStart!,
            canPanRight: !isFollowingLive && viewportEnd != nil && latest != nil && viewportEnd! < latest!,
            canZoomIn: chartVerticalZoomFactor < 64,
            canZoomOut: chartVerticalZoomFactor > 1,
            yAxisAbsRange: chartYAxisAbsRange(),
            yAxisCenter: chartYAxisCenter(points: visiblePoints),
            viewportStartMillis: viewportStart,
            viewportEndMillis: viewportEnd,
            sessionStartMillis: sessionStart,
            latestPointMillis: latest
        )
    }

    private func resolveViewportEnd(latest: UInt64) -> UInt64 {
        if isFollowingLive {
            return latest
        }
        return min(manualViewportEndMillis ?? latest, latest)
    }

    private func chartPanStepMillis(viewportEnd: UInt64) -> UInt64 {
        max(effectiveViewportDurationMillis(viewportEnd: viewportEnd) / 4, 1_000)
    }

    private func effectiveViewportDurationMillis(viewportEnd: UInt64) -> UInt64 {
        let sessionStart = sessionStartMillis ?? viewportEnd
        let availableDuration = viewportEnd > sessionStart ? viewportEnd - sessionStart : 0
        return min(chartWindowPreset.durationMillis, availableDuration)
    }

    private func chartYAxisAbsRange(zoomFactor: Float? = nil) -> Float {
        max(32_768 / (zoomFactor ?? chartVerticalZoomFactor), 256)
    }

    private func chartYAxisCenter(points: [ChartPoint]) -> Float {
        if let chartVerticalCenterOverride {
            return chartVerticalCenterOverride
        }
        guard !points.isEmpty else { return 0 }
        let values = points.map(\.value)
        return ((values.min() ?? 0) + (values.max() ?? 0)) / 2
    }

    private func slicePoints(_ points: [ChartPoint], startMillis: UInt64, endMillis: UInt64) -> ArraySlice<ChartPoint> {
        guard !points.isEmpty else { return [] }
        guard let firstIndex = points.firstIndex(where: { $0.timeMillis >= startMillis }) else { return [] }
        guard let lastIndex = points.lastIndex(where: { $0.timeMillis <= endMillis }), lastIndex >= firstIndex else { return [] }
        let startIndex = max(points.startIndex, firstIndex - 1)
        return points[startIndex...lastIndex]
    }

    private func downsampleVisiblePoints(_ points: [ChartPoint], maxPoints: Int) -> [ChartPoint] {
        guard points.count > maxPoints else { return points }
        let step = max(Int(ceil(Double(points.count) / Double(maxPoints))), 1)
        var result: [ChartPoint] = []
        var pendingSegmentBreak = false

        for (index, point) in points.enumerated() {
            pendingSegmentBreak = pendingSegmentBreak || point.startsNewSegment
            if index == 0 || index == points.count - 1 || index.isMultiple(of: step) {
                result.append(
                    ChartPoint(
                        timeMillis: point.timeMillis,
                        value: point.value,
                        startsNewSegment: result.isEmpty ? false : pendingSegmentBreak
                    )
                )
                pendingSegmentBreak = false
            }
        }
        return result
    }

    private static let maxRenderedChartPoints = 1_200
    private static let maxRetainedHistoryMillis: UInt64 = 15 * 60_000
}
