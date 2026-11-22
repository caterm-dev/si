import AppKit
import Testing
import SICore
import SILocalization
@testable import SIPresentation

@MainActor
struct CharacterPagingTests {
    @Test func everyCharacterCanBeScrolledToAndCommittedFromItsGridCell() throws {
        let characters = (0..<80).map { String(UnicodeScalar(0x4E00 + $0)!) }
        for (input, consumed) in [("bige", "bi"), ("bi'ge", "bi'")] {
            var session = InputSession(engine: CandidateEngine(providers: [CharacterProvider(characters: characters, consumed: consumed.count)]))
            session.configure(languages: [.simplifiedChinese])
            session.append(input)
            var selection = CandidateSelection()
            selection.update(session.candidates)
            selection.setExpanded(true)
            var seen: Set<String> = []
            for row in 0..<selection.rowCount {
                if row > 0 { selection.navigate(.row(1)) }
                #expect(selection.row == row)
                seen.formUnion(selection.displayedRange.map { selection.candidates[$0].text })
            }
            #expect(Set(characters).isSubset(of: seen) && seen.contains(input))
            let target = try #require(characters.last)
            let index = try #require(selection.candidates.firstIndex { $0.text == target && $0.isPartial })
            #expect(index >= 27)
            selection.move(by: -selection.selectedIndex)
            selection.navigate(.row(index / 6))
            selection.navigate(.column(index % 6))
            #expect(selection.selectedIndex == index)
            let view = CandidateListView()
            var clicked: String?
            view.onSelect = { clicked = $0 }
            view.render(selection)
            view.frame = NSRect(origin: .zero, size: view.preferredSize)
            view.layoutSubtreeIfNeeded()
            let row = view.rows[index - selection.displayedRange.lowerBound]
            row.performClick(nil)
            let chosen = try #require(selection.candidate(number: index % 6 + 1))
            #expect(clicked == chosen.id && row.isCurrent)
            #expect(row.accessibilityHelp()?.contains(L10n.format("Row %ld, column %ld", selection.row + 1, index % 6 + 1)) == true)
            if let path = ProcessInfo.processInfo.environment["SI_SPATIAL_PAGING_SNAPSHOT_PATH"] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    view.appearance = NSAppearance(named: appearance)
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.effectiveAppearance.performAsCurrentDrawingAppearance {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                    }
                    let style = appearance == .aqua ? "light" : "dark"
                    let spelling = input.contains("'") ? "separated" : "continuous"
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(filePath: "\(path).\(spelling).\(style).png"))
                }
            }
            let commit = session.commitResult(chosen, reason: .explicitSelection)
            #expect(commit.text == target && commit.input == consumed)
            #expect(commit.remainingInput == "ge" && session.buffer == "ge")
        }
    }
}

private struct CharacterProvider: CandidateProvider {
    let language = InputLanguage.simplifiedChinese
    let characters: [String]
    let consumed: Int

    func candidates(for input: String) -> [InputCandidate] {
        guard input.count > consumed else { return [] }
        return characters.enumerated().map { index, text in
            InputCandidate(text: text, language: language, score: characters.count - index,
                           consumedInputCount: consumed, lexicalTokenCount: 1)
        }
    }
}
