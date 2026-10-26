import SwiftUI

struct CompleteArchiveCard: View {
    @EnvironmentObject private var appState: AppViewModel
    private var russian: Bool { appState.selectedLanguage == .russian }
    var body: some View {
        AppCard(title: russian ? "Полный архив данных" : "Complete data archive") {
            Text(russian ? "Все доступные локальные данные всех животных и аккаунтов: база, версии анкет, записи, видео, исходники, логи и состояния загрузки. Исходные данные сохраняются. Удалённые файлы и данные только на сервере восстановить из этого архива нельзя. Токены доступа не включаются. Архив содержит анкеты и видео — выбирайте получателя внимательно."
                 : "All available local data across every animal and account: database, questionnaire versions, recordings, video, source files, logs and upload states. Original data is preserved. Deleted and server-only files cannot be recovered from this archive. Access tokens are excluded. The archive contains questionnaires and videos; choose its recipient carefully.")
                .font(.footnote).foregroundStyle(.secondary)
            if !appState.canChangeAccount && !appState.isCompleteArchiveExporting {
                Text(russian ? "Сначала остановите запись и дождитесь сохранения файлов и завершения операций с сервером." : "Stop recording and wait for its files and server operations to finish.")
                    .font(.footnote)
            }
            Button(russian ? "Создать полный ZIP" : "Create complete ZIP") { appState.prepareCompleteDataArchive() }
                .buttonStyle(.bordered)
                .disabled(!appState.canChangeAccount || appState.exportPhase != nil)
                .accessibilityIdentifier("archive.all.create")
            if let progress = appState.completeArchiveProgress {
                Text("\(progress.completedFiles)/\(progress.totalFiles) · \(progress.completedBytes / 1_024 / 1_024)/\(progress.totalBytes / 1_024 / 1_024) MB")
                    .font(.footnote)
            }
        }
    }
}
