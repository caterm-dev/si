import AppKit
import Foundation
import Testing
import SICore
@testable import SIPresentation

@MainActor
struct CandidateComparisonTests {
    private func fixture() -> ([InputCandidate], CandidateFusion) {
        let a = InputCandidate(text: "我们开慧", language: .simplifiedChinese, score: 1_000, lexicalTokenCount: 1)
        let b = InputCandidate(text: "我们开会", language: .simplifiedChinese, score: -1_000, lexicalTokenCount: 1)
        let en = InputCandidate(text: "welcome", language: .english, score: 48, lexicalTokenCount: 1)
        let literal = InputCandidate(text: "womenkaihui", language: nil, score: 0)
        let base = [a, b, en, literal]
        return (base, CandidateFusion(candidates: base,
            logProbabilities: [a.id: -30, b.id: -12, en.id: -25], weight: 1))
    }

    @Test func bothRowsUseTheirOwnFirstChoiceAndCannotCarryAcrossEdits() {
        let (base, fusion) = fixture()
        var selection = CandidateSelection()
        selection.update(base)
        selection.beginComparison()
        selection.receiveComparison(fusion)
        #expect(selection.selected?.id == base[0].id)
        selection.selectRanking(.ai)
        #expect(selection.candidate(number: 1)?.id == base[1].id)
        #expect(selection.confirmationReason(for: selection.selected) == .defaultAcceptance)
        #expect(selection.confirmationReason(for: base[0]) == .explicitSelection)
        selection.selectRanking(.base)
        #expect(selection.selected?.id == base[0].id)
        selection.update([base.last!])
        #expect(!selection.showsComparison && !selection.canSelectAI && selection.ranking == .base)
    }

    @Test func compactComparisonIsTwoSelectableRowsWithRealScoresAndAccessibleLabels() throws {
        let (base, fusion) = fixture()
        var selection = CandidateSelection()
        selection.update(base)
        selection.beginComparison()
        selection.receiveComparison(fusion)
        let view = CandidateListView()
        var clicked: (String, CandidateSelection.Ranking)?
        view.onSelectRanking = { clicked = ($0, $1) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = try #require(NSAppearance(named: appearance))
            view.render(selection)
            view.frame = NSRect(origin: .zero, size: view.preferredSize(constrainedTo: 700))
            view.layoutSubtreeIfNeeded()
            #expect(view.rows.map(\.candidateID) == base.map(\.id))
            #expect(view.comparisonRows.map(\.candidateID) == fusion.candidates.map(\.id))
            #expect(view.rows[0].frame.minY > view.comparisonRows[0].frame.maxY)
            #expect(view.comparisonRows[0].scoreLabel.stringValue.hasPrefix("AI "))
            #expect(!view.comparisonRows[0].scoreLabel.stringValue.contains("+"))
            #expect(view.comparisonRows.last?.scoreLabel.isHidden == true)
            #expect(view.comparisonRows[0].accessibilityLabel()?.contains("AI") == true)
            view.rows[0].performClick(nil)
            #expect(clicked?.0 == base[0].id && clicked?.1 == .base)
            view.comparisonRows[0].performClick(nil)
            #expect(clicked?.0 == base[1].id && clicked?.1 == .ai)
            if let path = ProcessInfo.processInfo.environment["SI_AI_SNAPSHOT_PATH"] {
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(filePath: "\(path).\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
        selection.selectRanking(.ai)
        selection.setExpanded(true)
        view.render(selection)
        #expect(view.comparisonRows.isEmpty && view.aiButton.isHidden)
        #expect(view.rows.first?.candidateID == base[1].id)
    }

    @Test func loadingFailureAndPendingRowsNeverPretendToBeAIResults() {
        let (base, _) = fixture()
        var selection = CandidateSelection()
        selection.update(base)
        selection.beginComparison()
        let view = CandidateListView()
        view.render(selection)
        #expect(view.comparisonRows.isEmpty && !view.comparisonLabel.stringValue.isEmpty)
        #expect(!view.aiButton.isEnabled)
        selection.receiveComparison(nil)
        view.render(selection)
        #expect(selection.comparisonState == .unavailable && view.comparisonRows.isEmpty)
        view.render(selection, isPending: true)
        #expect(view.rows.allSatisfy { !$0.isEnabled })
    }

    @Test(.enabled(if: SmallRerankerResources.directory.map {
        FileManager.default.fileExists(atPath: $0.appending(path: "runtime.json").path)
    } ?? false))
    func nativeModelMatchesPythonReferenceAndPartialBatches() async throws {
        let directory = try #require(SmallRerankerResources.directory)
        struct Manifest: Decodable { let validationScores: [Double] }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appending(path: "runtime.json")))
        let candidates = ["我们开会", "我们开慧", "Swift API", "🙂𠀀"].map {
            InputCandidate(text: $0, language: .simplifiedChinese, score: 0)
        }
        let scorer = SmallReranker(directory: directory)
        let scores = try await scorer.scores(for: candidates)
        for (index, candidate) in candidates.enumerated() {
            #expect(abs(try #require(scores[candidate.id]) - manifest.validationScores[index]) < 0.005)
        }
        let partial = try await scorer.scores(for: Array(candidates.prefix(2)))
        #expect(abs(try #require(partial[candidates[0].id]) - manifest.validationScores[0]) < 0.005)
    }

    @Test(.enabled(if: SmallRerankerResources.directory.map {
        FileManager.default.fileExists(atPath: $0.appending(path: "runtime.json").path)
    } ?? false))
    func actualDecoderAndModelRenderBothRankingsAndCommitExactChoices() async throws {
        let scorer = SmallReranker()
        var timings: [[String: Double]] = []
        for input in ["womenkaihui", "woxianganzhao", "cichuxiande", "ling"] {
            var session = InputSession()
            session.configure(languages: Set(InputLanguage.allCases))
            session.append(input)
            let original = session.candidates
            let start = ContinuousClock.now
            let scores = try await scorer.scores(for: original)
            let elapsed = start.duration(to: .now).components
            timings.append(["milliseconds": Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15,
                            "scoredCandidates": Double(scores.count)])
            #expect(!scores.isEmpty)
            let fusion = CandidateFusion(candidates: original, logProbabilities: scores, weight: 1)
            let modelScores = fusion.candidates.compactMap { fusion.scores[$0.id] }
            #expect(modelScores == modelScores.sorted(by: >))
            var selection = CandidateSelection()
            selection.update(original)
            let originalHead = selection.candidates.prefix(6).map(\.id)
            selection.beginComparison()
            selection.receiveComparison(fusion)
            #expect(selection.candidates(for: .base).prefix(6).map(\.id) == originalHead)
            let view = CandidateListView()
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                view.appearance = try #require(NSAppearance(named: appearance))
                view.render(selection)
                view.frame = NSRect(origin: .zero, size: view.preferredSize(constrainedTo: 1_100))
                view.layoutSubtreeIfNeeded()
                #expect(!view.rows.isEmpty && !view.comparisonRows.isEmpty)
                for row in view.rows + view.comparisonRows {
                    #expect(row.frame.maxX <= view.bounds.width - 32)
                    if view.preferredSize.width <= 1_100, !row.scoreLabel.isHidden {
                        #expect(row.scoreLabel.frame.width >= row.scoreLabel.intrinsicContentSize.width)
                    }
                }
                if let path = ProcessInfo.processInfo.environment["SI_AI_ENGINE_SNAPSHOT_PATH"] {
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(filePath: "\(path).\(input).\(appearance == .aqua ? "light" : "dark").png"))
                }
            }
            selection.selectRanking(.ai)
            let selected = try #require(selection.selected)
            let commit = session.commitResult(selected, reason: selection.confirmationReason(for: selected))
            #expect(commit.text.utf8.elementsEqual(selected.text.utf8))
            if let consumed = selected.consumedInputCount {
                #expect(commit.remainingInput == String(input.dropFirst(consumed)))
            } else {
                #expect(commit.remainingInput.isEmpty)
            }
        }
        if let path = ProcessInfo.processInfo.environment["SI_AI_TIMING_PATH"] {
            try JSONSerialization.data(withJSONObject: timings, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(filePath: path))
        }
    }

    @Test func obsoleteAndCancelledComparisonsCannotReplaceLatestCandidates() async {
        let gate = ScoreGate()
        var received: [UUID] = []
        let pipeline = CandidateRerankingPipeline(score: { await gate.score($0) }) { id, _ in
            received.append(id)
            gate.didReceive()
        }
        let first = UUID(), skipped = UUID(), latest = UUID()
        let (candidates, _) = fixture()
        pipeline.submit(id: first, candidates: candidates, weight: 1)
        await gate.waitForStarts(1)
        pipeline.submit(id: skipped, candidates: candidates, weight: 1)
        pipeline.invalidate()
        pipeline.submit(id: latest, candidates: candidates, weight: 1)
        gate.release(0)
        await gate.waitForStarts(2)
        #expect(received.isEmpty && gate.started == 2)
        gate.release(1)
        await gate.waitForReceipt()
        #expect(received == [latest])
        pipeline.submit(id: UUID(), candidates: candidates, weight: 1)
        await gate.waitForStarts(3)
        pipeline.invalidate()
        gate.release(2)
    }

    @MainActor
    private final class ScoreGate {
        private(set) var started = 0
        private var waiting: [CheckedContinuation<[String: Double], Never>] = []
        private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var receipt: CheckedContinuation<Void, Never>?
        private var received = false

        func score(_ candidates: [InputCandidate]) async -> [String: Double] {
            await withCheckedContinuation {
                waiting.append($0)
                started += 1
                let ready = startWaiters.filter { $0.0 <= started }
                startWaiters.removeAll { $0.0 <= started }
                ready.forEach { $0.1.resume() }
            }
        }
        func release(_ index: Int) { waiting[index].resume(returning: [:]) }
        func waitForStarts(_ count: Int) async {
            guard started < count else { return }
            await withCheckedContinuation { startWaiters.append((count, $0)) }
        }
        func didReceive() { received = true; receipt?.resume(); receipt = nil }
        func waitForReceipt() async {
            guard !received else { return }
            await withCheckedContinuation { receipt = $0 }
        }
    }
}
