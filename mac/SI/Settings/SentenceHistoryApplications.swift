import SwiftUI
import UniformTypeIdentifiers

struct SentenceHistoryApplications: View {
    let history: InputHistorySettings
    @State private var errorMessage: String?

    var body: some View {
        ForEach(history.sentenceApplications, id: \.self) { application in
            HStack {
                Text(application)
                Spacer()
                Button("Remove Application") { history.setSentenceCapture(false, in: application) }
                    .accessibilityLabel(L10n.format("Remove %@ from sentence capture", application))
            }
        }
        Button("Add Application…", action: addApplication)
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose an Application for Sentence Capture")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task {
                guard let application = await ApplicationDiscovery.shared.application(at: url) else {
                    errorMessage = L10n.text("This application does not provide a bundle identifier.")
                    return
                }
                history.setSentenceCapture(true, in: application.id)
                errorMessage = nil
            }
        }
    }
}
