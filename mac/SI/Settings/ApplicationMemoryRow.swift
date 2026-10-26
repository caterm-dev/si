import SwiftUI

struct ApplicationMemoryRow: View {
    let text: String
    let input: String
    let applicationID: String
    let count: Int
    let lastUsed: Date
    let forget: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.headline).textSelection(.enabled)
                Text(input).foregroundStyle(.secondary).textSelection(.enabled)
                Text(applicationID).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(L10n.format("Times used: %ld", count))
                    Text(lastUsed, format: .dateTime.year().month().day())
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Forget", role: .destructive, action: forget)
                .accessibilityLabel(L10n.format("Forget %@ in %@", text, applicationID))
        }
        .padding(.vertical, 4)
    }
}
