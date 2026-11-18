import SwiftUI

struct SettingsDetail: View {
    let page: SettingsPage
    let settings: LanguageSettings
    let updater: AppUpdater
    let applicationMemory: ApplicationMemorySettings
    let sentenceLearning: SentenceLearningSettings
    let inputHistory: InputHistorySettings

    var body: some View {
        switch page {
        case .typing:
            TypingSettingsPage(settings: settings)
        case .aiCompletion:
            AICompletionSettingsPage()
        case .directInput:
            ApplicationPassthroughSection(settings: settings)
        case .phrases:
            UserDictionarySection(dictionary: sentenceLearning)
        case .learning:
            ApplicationMemorySection(settings: applicationMemory)
        case .inputHistory:
            InputHistorySection(history: inputHistory)
        case .permissions:
            ExperimentPermissionsSection()
        case .about:
            AboutSettingsPage(updater: updater)
        }
    }
}
