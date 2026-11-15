import SwiftUI

struct SentenceLearningSection: View {
    @Bindable var settings: SentenceLearningSettings
    let vocabularyEnabled: Bool

    var body: some View {
        SettingsGroup("Sentence Learning") {
            SettingsRow(
                title: Text("Learn from Submitted Sentences"),
                detail: Text("After you confirm a candidate and press Return, SI can learn from the complete text in compatible single-line inputs, including edits and pasted text.")
            ) {
                Toggle("Learn from Submitted Sentences", isOn: $settings.enabled)
                    .labelsHidden()
                    .disabled(!vocabularyEnabled || settings.isLoading || settings.isClearing)
            }
            Text("On by default when Personal Learning is enabled. Learned words and word counts stay on this Mac and can change candidate ranking. SI discards the original sentence after processing it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = settings.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                if settings.canRetry {
                    Button("Retry Sentence Learning", action: settings.retry)
                }
            }
        }
    }
}
