import SwiftUI

struct ChartsView: View {
    @EnvironmentObject private var appState: AppViewModel
    @State private var isExportOptionsPresented = false
    @State private var pendingExportKind: ExportKind?
    @State private var isFullscreen = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                if let error = appState.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                ChartStatusLine()
                SensorSelector()
                ChartControls()
                DeviceChartView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
            .accessibilityHidden(isFullscreen)
            .navigationTitle(appState.text(.charts))
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $isFullscreen) {
                VStack(spacing: 10) {
                    HStack {
                        Button(appState.selectedLanguage == .russian ? "Выйти из полного экрана" : "Exit fullscreen") { isFullscreen = false }
                            .accessibilityIdentifier("chart.fullscreen.close")
                        Spacer()
                    }
                    SensorSelector()
                    ChartControls()
                    DeviceChartView()
                }
                .padding(12)
                .background(Color(uiColor: .systemBackground))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chart.fullscreen")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(appState.selectedLanguage == .russian ? "Полный экран" : "Fullscreen") { isFullscreen = true }
                        .accessibilityIdentifier("chart.fullscreen.open")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(appState.text(.export)) {
                        isExportOptionsPresented = true
                    }
                    .disabled(appState.exportPhase != nil)
                }
            }
            .sheet(isPresented: $isExportOptionsPresented, onDismiss: preparePendingExport) {
                ExportOptionsSheet(isPresented: $isExportOptionsPresented) { kind in
                    pendingExportKind = kind
                }
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func preparePendingExport() {
        guard let kind = pendingExportKind else { return }
        pendingExportKind = nil
        appState.prepareExport(kind)
    }
}

private struct ChartStatusLine: View {
    @EnvironmentObject private var appState: AppViewModel

    var body: some View {
        Text("\(appState.text(.status)): \(appState.statusText) | \(appState.text(.packets)) \(appState.packetsReceived) | \(appState.text(.lost)) \(appState.packetsLost) | \(appState.text(.rejected)) \(appState.packetsRejected)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .lineLimit(2)
            .multilineTextAlignment(.center)
    }
}

private struct SensorSelector: View {
    @EnvironmentObject private var appState: AppViewModel

    var body: some View {
        VStack(spacing: 8) {
            Picker(appState.text(.sensor), selection: Binding(
                get: { appState.selectedSensorType },
                set: { appState.selectSensorType($0) }
            )) {
                Text("T").tag(1)
                Text("AXL").tag(2)
                Text("GIR").tag(3)
                Text("MIC").tag(4)
            }
            .pickerStyle(.segmented)

            Picker(appState.text(.channel), selection: Binding(
                get: { appState.selectedChannel },
                set: { appState.selectChannel($0) }
            )) {
                ForEach(1...maxChannel, id: \.self) { channel in
                    Text("\(appState.text(.channel)) \(channel)").tag(channel)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var maxChannel: Int {
        appState.selectedSensorType == 2 || appState.selectedSensorType == 3 ? 3 : 1
    }
}

private struct ChartControls: View {
    @EnvironmentObject private var appState: AppViewModel

    var body: some View {
        VStack(spacing: 8) {
            Picker(appState.text(.window), selection: Binding(
                get: { appState.chart.windowPreset },
                set: { appState.selectChartWindow($0) }
            )) {
                ForEach(ChartWindowPreset.allCases, id: \.self) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Toggle(appState.text(.follow), isOn: Binding(
                    get: { appState.chart.isFollowingLive },
                    set: { appState.setFollowLive($0) }
                ))
                .toggleStyle(.button)

                Button {
                    appState.panChartLeft()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!appState.chart.canPanLeft)

                Button {
                    appState.panChartRight()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!appState.chart.canPanRight)

                Button {
                    appState.zoomChartOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(!appState.chart.canZoomOut)

                Button {
                    appState.zoomChartIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(!appState.chart.canZoomIn)

                Button(appState.text(.yReset)) {
                    appState.resetChartY()
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct DeviceChartView: View {
    @EnvironmentObject private var appState: AppViewModel
    @State private var previousDragFraction = 0.0
    @State private var previousMagnification: CGFloat = 1

    var body: some View {
        let chart = appState.chart
        VStack(alignment: .leading, spacing: 6) {
            if let summary = chartSummary(chart) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack {
                    if chart.points.isEmpty {
                        ContentUnavailableView(
                            appState.text(.noChartData),
                            systemImage: "chart.xyaxis.line",
                            description: Text("\(appState.text(.waitingForData)): \(appState.text(.sensor)) \(appState.selectedSensorType), \(appState.text(.channel)) \(appState.selectedChannel), \(appState.text(.window)) \(chart.windowPreset.rawValue).")
                        )
                    } else {
                        Canvas { context, size in
                            drawChart(chart, context: context, size: size)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            guard proxy.size.width > 0 else { return }
                            let currentFraction = -Double(value.translation.width / proxy.size.width)
                            appState.panChart(byFraction: currentFraction - previousDragFraction)
                            previousDragFraction = currentFraction
                        }
                        .onEnded { _ in
                            previousDragFraction = 0
                        }
                )
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            guard previousMagnification > 0 else { return }
                            let incrementalScale = value.magnification / previousMagnification
                            appState.zoomChart(scaleFactor: Float(incrementalScale), anchorFractionY: 0.5)
                            previousMagnification = value.magnification
                        }
                        .onEnded { _ in
                            previousMagnification = 1
                        }
                )
            }
        }
    }

    private func drawChart(_ chart: ChartUiState, context: GraphicsContext, size: CGSize) {
        guard
            let viewportStart = chart.viewportStartMillis,
            let viewportEnd = chart.viewportEndMillis
        else { return }

        let plotInset = EdgeInsets(top: 12, leading: 52, bottom: 28, trailing: 10)
        let plot = CGRect(
            x: plotInset.leading,
            y: plotInset.top,
            width: max(size.width - plotInset.leading - plotInset.trailing, 1),
            height: max(size.height - plotInset.top - plotInset.bottom, 1)
        )
        let minValue = chart.yAxisCenter - chart.yAxisAbsRange
        let maxValue = chart.yAxisCenter + chart.yAxisAbsRange
        let valueRange = max(maxValue - minValue, 1)
        let timeRange = max(Double(signedDelta(viewportEnd, viewportStart)), 1)

        for tick in yTicks(chart: chart) {
            let y = plot.maxY - CGFloat((tick.value - minValue) / valueRange) * plot.height
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(tick.value == 0 ? .secondary : Color.secondary.opacity(0.25)), lineWidth: tick.value == 0 ? 1.5 : 1)
            context.draw(Text(tick.label).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: plot.minX - 8, y: y), anchor: .trailing)
        }

        for tick in xTicks(chart: chart) {
            let x = plot.minX + CGFloat(Double(signedDelta(tick.timeMillis, viewportStart)) / timeRange) * plot.width
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(Color.secondary.opacity(0.18)), lineWidth: 1)
            context.draw(Text(tick.label).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: x, y: plot.maxY + 14), anchor: .center)
        }

        var path = Path()
        for (index, point) in chart.points.enumerated() {
            let x = plot.minX + CGFloat(Double(signedDelta(point.timeMillis, viewportStart)) / timeRange) * plot.width
            let clamped = min(max(point.value, minValue), maxValue)
            let y = plot.maxY - CGFloat((clamped - minValue) / valueRange) * plot.height
            if index == 0 || point.startsNewSegment {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(.accentColor), lineWidth: 2.5)
    }

    private func signedDelta(_ lhs: UInt64, _ rhs: UInt64) -> Int64 {
        lhs >= rhs ? Int64(lhs - rhs) : -Int64(rhs - lhs)
    }

    private func yTicks(chart: ChartUiState) -> [(label: String, value: Float)] {
        let halfRange = chart.yAxisAbsRange / 2
        return [
            chart.yAxisCenter + chart.yAxisAbsRange,
            chart.yAxisCenter + halfRange,
            chart.yAxisCenter,
            chart.yAxisCenter - halfRange,
            chart.yAxisCenter - chart.yAxisAbsRange
        ].map { (String(Int($0)), $0) }
    }

    private func xTicks(chart: ChartUiState) -> [(label: String, timeMillis: UInt64)] {
        guard
            let viewportStart = chart.viewportStartMillis,
            let viewportEnd = chart.viewportEndMillis,
            let sessionStart = chart.sessionStartMillis
        else { return [] }

        let duration = max(UInt64(max(signedDelta(viewportEnd, viewportStart), 0)), 1)
        return (0...4).map { index in
            let timeMillis = viewportStart + (duration * UInt64(index) / 4)
            return (relativeTimeLabel(signedDelta(timeMillis, sessionStart)), timeMillis)
        }
    }

    private func chartSummary(_ chart: ChartUiState) -> String? {
        guard
            let viewportStart = chart.viewportStartMillis,
            let viewportEnd = chart.viewportEndMillis,
            let sessionStart = chart.sessionStartMillis
        else { return nil }
        let mode = chart.isFollowingLive ? appState.text(.live) : appState.text(.history)
        let zoom = max(Int(32_768 / chart.yAxisAbsRange), 1)
        return "\(mode) | \(chart.windowPreset.rawValue) | \(zoom)x | \(relativeTimeLabel(signedDelta(viewportStart, sessionStart)))...\(relativeTimeLabel(signedDelta(viewportEnd, sessionStart)))"
    }

    private func relativeTimeLabel(_ millis: Int64) -> String {
        let totalSeconds = millis.magnitude / 1_000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let prefix = millis < 0 ? "-" : ""
        if minutes > 0 {
            return "\(prefix)\(minutes)m \(seconds)s"
        }
        return "\(prefix)\(seconds)s"
    }
}
