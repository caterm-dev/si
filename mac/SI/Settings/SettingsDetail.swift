import SwiftUI

struct SettingsDetail: View {
    let page: SettingsPage
    let settings: LanguageSettings
    let updater: AppUpdater
    let dictionary: UserDictionarySettings
    let applicationMemory: ApplicationMemorySettings
    let inputHistory: InputHistorySettings
    let sentenceHistory: InputHistorySettings

    var body: some View {
        switch page {
        case .typing:
            TypingSettingsPage(settings: settings)
        case .aiCompletion:
            AICompletionSettingsPage()
        case .directInput:
            ApplicationPassthroughSection(settings: settings)
        case .phrases:
            UserDictionarySection(dictionary: dictionary)
        case .learning:
            ApplicationMemorySection(settings: applicationMemory)
        case .inputHistory:
            InputHistorySection(history: inputHistory)
        case .sentenceHistory:
            InputHistorySection(history: sentenceHistory)
        case .permissions:
            ExperimentPermissionsSection()
        case .about:
            AboutSettingsPage(updater: updater)
        }
    }
}
