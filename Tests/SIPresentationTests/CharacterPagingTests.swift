import AppKit
import Testing
import SICore
import SILocalization
@testable import SIPresentation

@MainActor
struct CharacterPagingTests {
    @Test func everyCharacterCanBePagedToAndCommittedFromItsGridCell() throws {
        let characters = (0..<80).map { String(UnicodeScalar(0x4E00 + $0)!) }
        let decoder = PinyinDecoder(entries: characters.map { PinyinLexiconEntry(syllables: ["bi"], text: $0) }
            + [PinyinLexiconEntry(syllables: ["ge"], text: "个")])
        for (input, consumed) in [("bige", "bi"), ("bi'ge", "bi'")] {
            var session = InputSession(engine: CandidateEngine(providers: [CharacterProvider(decoder: decoder)]))
            session.configure(languages: [.simplifiedChinese])
            session.append(input)
            var selection = CandidateSelection()
            selection.update(session.candidates)
            selection.setExpanded(true)
            #expect(selection.pageCount >= 4)
            var seen: Set<String> = []
            for page in 0..<selection.pageCount {
                if page > 0 { selection.navigate(.page(1)) }
                #expect(selection.page == page)
                seen.formUnion(selection.displayedRange.map { selection.candidates[$0].text })
            }
            #expect(Set(characters).isSubset(of: seen) && seen.contains(input))
            let target = try #require(characters.last)
            let index = try #require(selection.candidates.firstIndex { $0.text == target && $0.isPartial })
            #expect(index >= 27)
            selection.move(by: -selection.selectedIndex)
            selection.navigate(.page(index / 24))
            selection.navigate(.row(index % 24 / 6))
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
            #expect(view.pageLabel.stringValue == "\(selection.page + 1) / \(selection.pageCount)")
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
    let decoder: PinyinDecoder
    func candidates(for input: String) -> [InputCandidate] {
        decoder.compositionCandidates(for: input, languages: [.simplifiedChinese])
    }
}
