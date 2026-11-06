import SwiftUI

struct SettingsView: View {
    @Bindable var settings: LanguageSettings
    var updater: AppUpdater
    var dictionary: UserDictionarySettings = .shared
    var applicationMemory: ApplicationMemorySettings = .shared
    var inputHistory: InputHistorySettings = .shared
    var sentenceHistory: InputHistorySettings = .sentences

    @State private var search = ""
    @State private var selectedPage: SettingsPage = .typing

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = SettingsPage.groups.compactMap { group in
            let pages = group.pages.filter { $0.matches(query) }
            return pages.isEmpty ? nil : (title: group.title, pages: pages)
        }
        let matches = groups.flatMap(\.pages)
        let visiblePage = matches.contains(selectedPage) ? selectedPage : matches.first

        HStack(spacing: 0) {
            SettingsSidebar(search: $search, selection: visiblePage, groups: groups) { selectedPage = $0 }
            Divider()
            if let visiblePage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(L10n.text(visiblePage.title))
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        SettingsDetail(
                            page: visiblePage, settings: settings, updater: updater, dictionary: dictionary,
                            applicationMemory: applicationMemory, inputHistory: inputHistory, sentenceHistory: sentenceHistory
                        )
                    }
                    .frame(maxWidth: 700, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 26)
                    .frame(maxWidth: .infinity)
                }
                .id(visiblePage)
                .focusSection()
            } else {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: 760, minHeight: 520)
        .toggleStyle(.switch)
    }
}

#Preview {
    SettingsView(settings: LanguageSettings(defaults: UserDefaults(suiteName: "SI.Preview") ?? .standard), updater: AppUpdater(),
                 dictionary: UserDictionarySettings(isPreview: true),
                 applicationMemory: ApplicationMemorySettings(isPreview: true),
                 inputHistory: InputHistorySettings(isPreview: true),
                 sentenceHistory: InputHistorySettings(isPreview: true, kind: .sentences))
}
