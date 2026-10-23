import SwiftUI

struct SettingsView: View {
    @Bindable var settings: LanguageSettings
    var updater: AppUpdater
    var personalization: PersonalizationSettings = .shared
    var dictionary: UserDictionarySettings = .shared
    var applicationMemory: ApplicationMemorySettings = .shared

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
                Section {
                    Toggle("Automatically confirm stable prefixes", isOn: $settings.automaticConfirmationEnabled)
                    Picker("Punctuation during composition", selection: $settings.punctuationBehavior) {
                        ForEach(PunctuationBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                } header: {
                    Text("Typing")
                } footer: {
                    Text("Automatic confirmation commits stable leading Chinese words as you continue typing or pause, keeping the ending editable. Editing or choosing candidates pauses it until you type again. It does not train personal learning. Return and shortcuts keep the remaining original spelling.")
                    Text(settings.punctuationBehavior.explanation + " Punctuation outside composition passes through unchanged.")
                }
                Section("Try the candidate engine") {
                    CandidatePreviewView(settings: settings, personalization: personalization, dictionary: dictionary,
                                         applicationMemory: applicationMemory)
                }
                ApplicationMemorySection(settings: applicationMemory)
                PersonalizationView(personalization: personalization)
                UserDictionarySection(dictionary: dictionary)
                UpdateSettingsSection(updater: updater)
                Section("Development Preview") {
                    Text("SI offers Chinese conversion and English suggestions through one input source, with personal phrases and optional local learning. Chinese sentence quality and host-app compatibility are still under development.")
                        .foregroundStyle(.secondary)
                    Text("Space selects a candidate. Return keeps the original text. Escape cancels. Left and Right edit the composition; Up, Down, page keys, and number keys navigate candidates.")
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
    SettingsView(settings: LanguageSettings(defaults: UserDefaults(suiteName: "SI.Preview") ?? .standard), updater: AppUpdater(),
                 personalization: PersonalizationSettings(isPreview: true), dictionary: UserDictionarySettings(isPreview: true),
                 applicationMemory: ApplicationMemorySettings(isPreview: true))
}
