import SwiftUI

struct SettingsRow<Control: View>: View {
    let title: Text
    var detail: Text?
    @ViewBuilder var control: Control

    var body: some View {
        LabeledContent {
            control
                .fixedSize(horizontal: true, vertical: false)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                title
                detail?
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
