import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationPassthroughView: View {
    let settings: LanguageSettings
    @Environment(\.dismiss) private var dismiss
    @State private var applications: [InstalledApplication] = []
    @State private var search = ""
    @State private var isLoading = true
    @State private var refreshGeneration = 0
    @State private var errorMessage: String?

    private var visibleApplications: [InstalledApplication] {
        var byID = Dictionary(uniqueKeysWithValues: applications.map { ($0.id, $0) })
        for id in settings.passthroughApplications where byID[id] == nil {
            byID[id] = InstalledApplication(id: id, name: id)
        }
        return byID.values.filter {
            search.isEmpty || $0.name.localizedStandardContains(search) || $0.id.localizedStandardContains(search)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Direct Input by Application").font(.title2.bold())
            Text("Turn on direct input for apps where you want keys to pass through unchanged. This applies to the entire app, including every browser tab or editor pane.")
                .foregroundStyle(.secondary)
            TextField("Search applications", text: $search).textFieldStyle(.roundedBorder)
            List(visibleApplications) { application in
                ApplicationPassthroughRow(application: application, settings: settings)
            }
            .overlay {
                if isLoading { ProgressView("Finding applications…") }
                else if visibleApplications.isEmpty {
                    ContentUnavailableView("No Matching Applications", systemImage: "app.dashed",
                                           description: Text("Try another search or add an application."))
                }
            }
            Text("Lists apps in standard Applications folders and running apps. Use Add Application for apps stored elsewhere. Enabled rules remain available after an app is removed.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Button("Add Application…", action: addApplication).disabled(isLoading)
                Button("Refresh") { refreshGeneration &+= 1 }.disabled(isLoading)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 620, minHeight: 480)
        .task(id: refreshGeneration) { await loadApplications() }
    }

    private func loadApplications() async {
        isLoading = true
        let runningURLs = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }.compactMap(\.bundleURL)
        let found = await ApplicationDiscovery.shared.applications(including: runningURLs)
        guard !Task.isCancelled else { return }
        applications = found
        isLoading = false
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.title = "Add Application"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let application = await ApplicationDiscovery.shared.application(at: url) else {
                    errorMessage = "This application does not provide a bundle identifier."
                    return
                }
                applications.removeAll { $0.id == application.id }
                applications.append(application)
                search = ""
                errorMessage = nil
            }
        }
    }
}
