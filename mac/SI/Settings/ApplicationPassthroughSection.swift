import SwiftUI

struct ApplicationPassthroughSection: View {
    let settings: LanguageSettings
    @State private var showsApplications = false

    var body: some View {
        SettingsGroup("Applications") {
            SettingsRow(
                title: Text("Direct Input"),
                detail: Text(L10n.format("Applications using direct input: %ld", settings.passthroughApplications.count))
            ) {
                Button("Manage Direct Input…") { showsApplications = true }
            }
            Divider()
            Text("Pass keys directly to selected apps, such as Terminal, without candidates or automatic conversion. All apps use normal SI input by default. Direct input also stops SI vocabulary learning for that app; saved data is kept.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showsApplications) { ApplicationPassthroughView(settings: settings) }
    }
}
