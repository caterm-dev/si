import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationPassthroughRow: View {
    let application: InstalledApplication
    let settings: LanguageSettings
    @State private var icon: NSImage?
    @ScaledMetric private var iconSize = 32

    private var isEnabled: Binding<Bool> {
        Binding(get: { settings.usesPassthrough(in: application.id) },
                set: { settings.setPassthrough($0, for: application.id) })
    }

    var body: some View {
        Toggle(isOn: isEnabled) {
            HStack(spacing: 10) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "app").resizable().scaledToFit().foregroundStyle(.secondary)
                    }
                }
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(application.name)
                    Text(application.id).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .accessibilityLabel("Direct input for \(application.name), \(application.id)")
        .padding(.vertical, 4)
        .task(id: application.bundleURL) { loadIcon() }
    }

    private func loadIcon() {
        if let url = application.bundleURL {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSWorkspace.shared.icon(for: .applicationBundle)
        }
    }
}
