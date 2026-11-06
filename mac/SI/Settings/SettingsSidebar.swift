import SwiftUI

struct SettingsSidebar: View {
    @Binding var search: String
    let selection: SettingsPage?
    let groups: [(title: String, pages: [SettingsPage])]
    let selectPage: (SettingsPage) -> Void
    @FocusState private var focusedPage: SettingsPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 16)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search Settings", text: $search, prompt: Text("Search Settings").foregroundStyle(.secondary))
                    .textFieldStyle(.plain)
                    .onKeyPress(.escape) {
                        guard !search.isEmpty else { return .ignored }
                        search = ""
                        return .handled
                    }
                if !search.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { search = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary, in: .capsule)
            .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text(group.title))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 4)
                            ForEach(group.pages, id: \.self) { page in
                                Button {
                                    focusedPage = page
                                    selectPage(page)
                                } label: {
                                    Label(L10n.text(page.sidebarTitle), systemImage: page.icon)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(
                                            selection == page ? Color.primary.opacity(0.09) : .clear,
                                            in: .rect(cornerRadius: 8)
                                        )
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .focusable()
                                .focused($focusedPage, equals: page)
                                .accessibilityAddTraits(selection == page ? .isSelected : [])
                                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                                    moveSelection(from: page, offset: press.key == .upArrow ? -1 : 1)
                                    return .handled
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .accessibilityLabel("Settings Categories")
        }
        .padding(.top, 20)
        .frame(width: 214)
        .background(.primary.opacity(0.035))
        .focusSection()
    }

    private func moveSelection(from page: SettingsPage, offset: Int) {
        let pages = groups.flatMap(\.pages)
        guard let index = pages.firstIndex(of: page) else { return }
        let next = index + offset
        guard pages.indices.contains(next) else { return }
        focusedPage = pages[next]
        selectPage(pages[next])
    }
}
