import SwiftUI

struct ApplicationPassthroughSection: View {
    let settings: LanguageSettings
    @State private var showsApplications = false
    @State private var recordsShortcut = false

    var body: some View {
        SettingsGroup("Applications") {
            SettingsRow(
                title: Text("Direct Input"),
                detail: Text(L10n.format("Applications using direct input: %ld", settings.passthroughApplications.count))
            ) {
                Button("Manage Direct Input…") { showsApplications = true }
            }
            Divider()
            SettingsRow(title: Text("Toggle Direct Input Shortcut"), detail: Text(settings.directInputShortcut.displayName)) {
                HStack {
                    Button("Record Shortcut…") { recordsShortcut = true }
                    Button("Reset Shortcut") { settings.directInputShortcut = .default }
                        .disabled(settings.directInputShortcut == .default)
                }
            }
            Text("While SI is selected, toggle direct input for the current app. The rule is saved for the entire app.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            Text("Pass keys directly to selected apps, such as Terminal, without candidates or automatic conversion. All apps use normal SI input by default. Direct input also stops SI vocabulary learning for that app; saved data is kept.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $recordsShortcut) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Record Direct Input Shortcut").font(.headline)
                Text("Press a letter, number or punctuation key with Control, Option or Command. Escape cancels.")
                DirectInputShortcutRecorder(onRecord: { shortcut in
                    settings.directInputShortcut = shortcut
                    recordsShortcut = false
                }, onCancel: { recordsShortcut = false })
                    .frame(height: 1)
                Button("Cancel", role: .cancel) { recordsShortcut = false }
            }
            .padding(24)
            .frame(width: 440)
        }
        .sheet(isPresented: $showsApplications) { ApplicationPassthroughView(settings: settings) }
    }
}
