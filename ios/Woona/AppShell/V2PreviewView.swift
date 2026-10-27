import SwiftUI

struct V2PreviewView: View {
    @EnvironmentObject private var appState: AppViewModel
    @ObservedObject var controller: V2PreviewController
    var showCharts = false
    @State private var confirmingDisconnect = false
    private var russian: Bool { appState.selectedLanguage == .russian }
    private var state: V2PreviewSnapshot { controller.snapshot }

    var body: some View {
        AppCard(title: russian ? "Предпросмотр V2" : "V2 preview") {
            Text(v2PreviewDisclaimer(russian: russian)).font(.footnote)
            Text(v2PreviewFirmwareWarning(russian: russian)).font(.footnote).foregroundStyle(.orange)
            Text((russian ? "Статус: " : "Status: ") + stageText).font(.headline).accessibilityIdentifier("v2.stage")
            if let reason = state.reason {
                Text(russian ? "Предпросмотр не подтверждён или прерван. Проверьте датчик. Повторное обычное подключение возможно после явного отключения." : "Preview is unconfirmed or interrupted. Check the sensor. Disconnect explicitly before making a new connection.")
                    .font(.footnote).foregroundStyle(.red)
                Text(reason).font(.caption).textSelection(.enabled).accessibilityIdentifier("v2.error")
            }
            if let mode = state.busySessionMode, mode == 1 || mode == 2 {
                Text(russian ? "Датчик занят существующей сессией. Приложение не отправляет её остановку и сохраняет соединение; отключение Bluetooth может остановить SD-запись." : "The sensor is busy with an existing session. The app does not stop it and keeps the connection; disconnecting Bluetooth may stop an SD recording.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            ForEach(state.streams, id: \.id) { stream in
                Toggle(isOn: Binding(get: { state.selectedMask & bit(stream.id) != 0 }, set: { selected in
                    let mask = state.selectedMask
                    controller.select(mask: selected ? mask | bit(stream.id) : mask & ~bit(stream.id))
                })) {
                    Text(streamName(stream.id, russian: russian) + " · \(stream.nativeRateHz) Hz")
                }
                .disabled(![.ready, .stopped].contains(state.stage))
                .accessibilityIdentifier("v2.stream.\(stream.id)")
            }
            HStack {
                Button(russian ? "Начать предпросмотр" : "Start preview") { controller.start() }
                    .disabled(![.ready, .stopped].contains(state.stage) || state.selectedMask == 0)
                    .accessibilityIdentifier("v2.start")
                Button(russian ? "Остановить предпросмотр" : "Stop preview") { controller.stop() }
                    .disabled(state.stage != .running)
                    .accessibilityIdentifier("v2.stop")
            }.buttonStyle(.bordered)
            Button(russian ? "Отключить" : "Disconnect") { confirmingDisconnect = true }
                .buttonStyle(.bordered).accessibilityIdentifier("v2.disconnect")
            Text(russian ? "Сохранение V2 и чтение SD пока недоступны." : "V2 recording and SD download are not available yet.")
                .font(.caption).foregroundStyle(.secondary)
            Text(russian ? "Декодировано блоков: \(state.decodedBlocks). Разрывов последовательности: \(state.wireGaps). Отклонено кадров: \(state.rejectedFrames). Не показано блоков: \(state.skippedUIBlocks)." : "Decoded blocks: \(state.decodedBlocks). Sequence gaps: \(state.wireGaps). Rejected frames: \(state.rejectedFrames). UI-skipped blocks: \(state.skippedUIBlocks).")
                .font(.caption).accessibilityIdentifier("v2.counters")
            if showCharts {
                if state.channels.isEmpty { Text(russian ? "Нет данных для графика с корректными временными метками." : "No chart data with valid timestamps yet.").font(.footnote) }
                ForEach(state.channels) { channel in
                    VStack(alignment: .leading) {
                        Text(streamName(channel.streamID, russian: russian) + " · \(channel.channel + 1) · raw").font(.caption)
                        V2PreviewPlot(points: channel.points).frame(height: 110)
                        if let first = channel.points.first, let last = channel.points.last {
                            Text(String(format: "%.3f–%.3f s · %d", first.time, last.time, channel.points.count)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .alert(russian ? "Отключить датчик?" : "Disconnect sensor?", isPresented: $confirmingDisconnect) {
            Button(russian ? "Отключить" : "Disconnect", role: .destructive) { appState.disconnectV2Preview() }
            Button(russian ? "Отмена" : "Cancel", role: .cancel) {}
        } message: {
            Text(russian ? "Отключение может остановить запись на SD-карту. Продолжить?" : "Disconnecting may stop an SD-card recording. Continue?")
        }
    }

    private func bit(_ id: Int) -> UInt32 { UInt32(1) << (id - 1) }
    private var stageText: String {
        switch state.stage {
        case .idle: return russian ? "Не запущен" : "Idle"
        case .connecting: return russian ? "Подключение" : "Connecting"
        case .checking: return russian ? "Проверка" : "Checking"
        case .ready: return russian ? "Готов" : "Ready"
        case .starting: return russian ? "Запуск" : "Starting"
        case .running: return russian ? "Идёт предпросмотр" : "Running"
        case .stopping: return russian ? "Остановка" : "Stopping"
        case .stopped: return russian ? "Остановлен" : "Stopped"
        case .failed: return russian ? "Ошибка" : "Failed"
        }
    }
}

func v2PreviewDisclaimer(russian: Bool) -> String {
    russian ? "Поток для проверки датчика. Сессия и видео не сохраняются и не загружаются." : "A sensor test stream. Sessions and video are not saved or uploaded."
}

func v2PreviewFirmwareWarning(russian: Bool) -> String {
    russian ? "Подключайте только свободный датчик. В текущей прошивке разрыв Bluetooth может остановить запись на SD-карту." : "Connect only to an idle sensor. With the current firmware, a Bluetooth disconnect can stop an SD-card recording."
}

private func streamName(_ id: Int, russian: Bool) -> String {
    switch id {
    case 1: return russian ? "Акселерометр" : "Accelerometer"
    case 2: return russian ? "Гироскоп" : "Gyroscope"
    case 3: return russian ? "Контактный микрофон" : "Contact microphone"
    case 4: return russian ? "Окружающий звук" : "Ambient sound"
    case 5: return russian ? "Пьезодатчик" : "Piezo"
    case 6: return "T1 (raw)"
    case 7: return "T2 (raw)"
    default: return "Stream \(id)"
    }
}

private struct V2PreviewPlot: View {
    let points: [V2PreviewPoint]
    var body: some View {
        Canvas { context, size in
            guard let first = points.first, let last = points.last else { return }
            let minimum = points.map(\.value).min() ?? 0
            let maximum = points.map(\.value).max() ?? 1
            let width = max(last.time - first.time, 0.001)
            let height = max(maximum - minimum, 1)
            var path = Path()
            for (index, point) in points.enumerated() {
                let position = CGPoint(x: CGFloat((point.time - first.time) / width) * size.width,
                                       y: size.height - CGFloat((point.value - minimum) / height) * size.height)
                if index == 0 || point.breakBefore { path.move(to: position) }
                else { path.addLine(to: position) }
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 1)
        }
        .background(Color.woonaBackground)
        .accessibilityLabel("V2 raw sensor chart")
    }
}
