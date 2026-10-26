import SwiftUI

struct ApplicationPassthroughSection: View {
    let settings: LanguageSettings
    @State private var showsApplications = false

    var body: some View {
        Section {
            Text("\(settings.passthroughApplications.count) applications use direct input")
                .foregroundStyle(.secondary)
            Button("Manage Direct Input…") { showsApplications = true }
        } header: {
            Text("Direct Input by Application")
        } footer: {
            Text("Pass keys directly to selected apps, such as Terminal, without candidates or automatic conversion. All apps use normal SI input by default. Direct input also stops SI vocabulary learning and history recording for that app; saved data is kept.")
        }
        .sheet(isPresented: $showsApplications) { ApplicationPassthroughView(settings: settings) }
    }
}
