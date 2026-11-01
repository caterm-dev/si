import SwiftUI

struct InputHistoryRow: View {
    let entry: InputHistoryEntry
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Original Input") { Text(entry.input).textSelection(.enabled) }
                LabeledContent("Submitted Text") { Text(entry.text).textSelection(.enabled) }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Delete", role: .destructive, action: delete)
                .accessibilityLabel(L10n.text("Delete this history record"))
        }
        .padding(.vertical, 4)
    }
}
