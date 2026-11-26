import SwiftUI
#if SWIFT_PACKAGE
import SICore
#endif

struct TypingSettingsPage: View {
    @Bindable var settings: LanguageSettings

    var body: some View {
        SettingsGroup("Languages") {
            SettingsRow(title: Text("English")) {
                Toggle("English", isOn: $settings.englishEnabled)
                    .labelsHidden()
            }
            Divider()
            SettingsRow(title: Text("Chinese (Simplified)")) {
                Toggle("Chinese (Simplified)", isOn: $settings.chineseEnabled)
                    .labelsHidden()
            }
            Text("Enabled languages work together. When input matches more than one language, SI shows their candidates together. You can always keep the original text.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        SettingsGroup("Composition") {
            SettingsRow(
                title: Text("Local model ranking"),
                detail: Text("Use preceding text to help rank whole-input candidates on this Mac.")
            ) {
                Toggle("Local model ranking", isOn: $settings.localModelRankingEnabled)
                    .labelsHidden()
            }
            Divider()
            SettingsRow(
                title: Text("Pinyin correction"),
                detail: Text("Offer spelling suggestions. Press Space to accept a correction highlighted in first place.")
            ) {
                Toggle("Pinyin correction", isOn: $settings.pinyinCorrectionEnabled)
                    .labelsHidden()
            }
            Divider()
            SettingsRow(
                title: Text("Show punctuation candidates"),
                detail: Text("Offer English or Chinese symbols for common punctuation keys.")
            ) {
                Toggle("Show punctuation candidates", isOn: $settings.punctuationCandidatesEnabled)
                    .labelsHidden()
            }
            Divider()
            SettingsRow(
                title: Text("Punctuation during composition"),
                detail: Text(L10n.text(settings.punctuationBehavior.explanation))
            ) {
                Picker("Punctuation during composition", selection: $settings.punctuationBehavior) {
                    ForEach(PunctuationBehavior.allCases) { behavior in
                        Text(L10n.text(behavior.displayName)).tag(behavior)
                    }
                }
                .labelsHidden()
            }
        }
    }
}
