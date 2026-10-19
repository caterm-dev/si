import SwiftUI

struct SettingsView: View {
    @Bindable var settings: LanguageSettings
    var personalization: PersonalizationSettings = .shared
    var dictionary: UserDictionarySettings = .shared

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
                    Picker("Punctuation during composition", selection: $settings.punctuationBehavior) {
                        ForEach(PunctuationBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                } header: {
                    Text("Typing")
                } footer: {
                    Text(settings.punctuationBehavior.explanation + " Return and shortcuts always keep the original spelling. Punctuation outside composition passes through unchanged.")
                }
                Section("Try the candidate engine") {
                    CandidatePreviewView(settings: settings, personalization: personalization, dictionary: dictionary)
                }
                PersonalizationView(personalization: personalization)
                UserDictionarySection(dictionary: dictionary)
                Section("Development Preview") {
                    Text("SI combines original English and Pinyin vocabularies, mixed-language composition, personal phrases, and optional local learning. The vocabulary is still limited; broad language coverage, sentence-level context, and host-app compatibility are in development.")
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
    SettingsView(settings: LanguageSettings(defaults: UserDefaults(suiteName: "SI.Preview") ?? .standard),
                 personalization: PersonalizationSettings(isPreview: true), dictionary: UserDictionarySettings(isPreview: true))
}
