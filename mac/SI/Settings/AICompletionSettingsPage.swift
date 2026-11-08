import SwiftUI

struct AICompletionSettingsPage: View {
    @Bindable var settings: AICompletionSettings = .shared
    var permissions: ExperimentPermissions = .shared
    @State private var apiKey = ""
    @State private var savingKey = false
    @State private var editingPath = false
    @State private var pathDraft = ""
    @State private var savingPath = false
    @State private var pathError: String?

    var body: some View {
        SettingsGroup("AI Completion") {
            Toggle("Enable AI Completion", isOn: $settings.enabled)
            Text("Press Tab while composing to send your current input, available input-field text, and a screenshot of the current window to the selected AI provider. This applies to all apps where SI conversion is active. CLI providers may send this data to their online services.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Press Tab to request a prediction, then press Tab again or click the AI row to insert the result. Screen Recording permission is required.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Prediction Provider", selection: $settings.provider) {
                ForEach(AICompletionProvider.allCases, id: \.self) { provider in
                    Text(L10n.text(provider.title)).tag(provider)
                }
            }
            if settings.provider == .openAI {
                SecureField("OpenAI API Key", text: $apiKey)
                    .textContentType(.password)
                HStack {
                    Button("Save Key") { updateKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .disabled(savingKey || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove Key", role: .destructive) { updateKey(nil) }
                        .disabled(savingKey || !settings.hasAPIKey)
                    Text(settings.hasAPIKey ? "Key saved in Keychain" : "No API key saved")
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Executable Path").font(.callout.weight(.medium))
                        Text(settings.resolvedCLIPath ?? settings.cliPath ?? L10n.text("CLI not found"))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Edit") {
                        pathDraft = settings.cliPath ?? settings.resolvedCLIPath ?? ""
                        pathError = nil
                        editingPath = true
                    }
                    .accessibilityLabel("Edit executable path")
                }
                if settings.cliPath != nil {
                    Button("Use Automatic Discovery") {
                        Task { await settings.setCLIPath(nil) }
                    }
                }
            }
            LabeledContent("Last Prediction") {
                Text(AICompletionActivity.shared.phase?.message ?? L10n.text("No prediction has been attempted yet."))
                    .foregroundStyle(.secondary)
            }
            if let error = settings.error {
                Text(L10n.text(error)).font(.callout).foregroundStyle(.red)
            }
        }
        Button("Open Screen Recording Settings…", action: permissions.openScreenRecordingSettings)
        .sheet(isPresented: $editingPath) { executablePathEditor }
        .task(id: settings.provider) {
            await settings.refreshCLIPath()
            await settings.refreshCredentialStatus()
            while !Task.isCancelled {
                permissions.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onChange(of: settings.provider) { apiKey = "" }
    }

    private func updateKey(_ value: String?) {
        savingKey = true
        Task {
            await settings.saveAPIKey(value)
            apiKey = ""
            savingKey = false
        }
    }

    private var executablePathEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Executable Path").font(.headline)
            Text("Enter the full path to your installed CLI executable. You can use ~/ for your home folder.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Executable Path", text: $pathDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { saveExecutablePath() }
                .disabled(savingPath)
            if let pathError { Text(L10n.text(pathError)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { editingPath = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(savingPath)
                Button("Save", action: saveExecutablePath)
                    .keyboardShortcut(.defaultAction)
                    .disabled(savingPath || pathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(savingPath)
    }

    private func saveExecutablePath() {
        guard !savingPath else { return }
        savingPath = true
        let path = pathDraft
        Task {
            let saved = await settings.setCLIPath(path)
            savingPath = false
            if saved { editingPath = false }
            else { pathError = settings.error }
        }
    }

}
