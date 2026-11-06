import SwiftUI

struct AboutSettingsPage: View {
    let updater: AppUpdater

    var body: some View {
        SettingsGroup("Development Preview") {
            Text("One input. Every language.")
                .font(.headline)
            Text("SI offers Chinese conversion and English suggestions through one input source, with personal phrases and optional local learning. Chinese sentence quality and host-app compatibility are still under development.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Link("View SI on GitHub", destination: Self.repositoryURL)
        }
        UpdateSettingsSection(updater: updater)
        SettingsGroup("Keyboard Shortcuts") {
            Text("Space selects a candidate. Return keeps the original text. Escape cancels. Left and Right edit the composition; Up, Down, page keys, and number keys navigate candidates.")
                .foregroundStyle(.secondary)
        }
    }

    private static let repositoryURL = URL(string: "https://github.com/caterm-dev/si") ?? URL(filePath: "/")
}
