import SwiftUI

struct SettingsView: View {
    @Bindable var settings: LanguageSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SI").font(.largeTitle.bold())
            Text("One input. Every language.").font(.title3).foregroundStyle(.secondary)
            Form {
                Section {
                    Toggle("English", isOn: $settings.englishEnabled)
                    Toggle("Chinese (Simplified)", isOn: $settings.chineseEnabled)
                } header: {
                    Text("Languages")
                } footer: {
                    Text("Enabled languages work together. When input matches more than one language, SI shows their candidates together. You can always keep the original text.")
                }
                Section("Try the candidate engine") {
                    CandidatePreviewView(settings: settings)
                }
                Section("Development Preview") {
                    Text("SI currently uses a small offline English vocabulary and an exact-match Pinyin demo lexicon. Full Pinyin decoding, phrase segmentation, and contextual ranking are planned.")
                        .foregroundStyle(.secondary)
                    Text("Space selects a candidate. Return keeps the original text. Escape cancels composition. Use arrow keys and number keys in the candidate window.")
                        .foregroundStyle(.secondary)
                    Link("View SI on GitHub", destination: Self.repositoryURL)
                }
            }
            .formStyle(.grouped)
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 600)
    }

    private static let repositoryURL = URL(string: "https://github.com/caterm-dev/si") ?? URL(filePath: "/")
}

#Preview {
    SettingsView(settings: LanguageSettings(defaults: UserDefaults(suiteName: "SI.Preview") ?? .standard))
}
