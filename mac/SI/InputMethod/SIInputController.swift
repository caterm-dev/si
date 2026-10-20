import AppKit
import InputMethodKit

// InputMethodKit resolves this stable Objective-C name from Info.plist.
@MainActor
@objc(SIInputController)
// The legacy superclass is not Sendable. All mutable state remains main-actor isolated.
final class SIInputController: IMKInputController, @unchecked Sendable {
    private var session = InputSession(candidateGeneration: .deferred)
    private weak var candidateClient: (any IMKTextInput)?
    private lazy var candidatePipeline = CandidatePipeline { [weak self] result in
        self?.receiveCandidates(result)
    }
    private lazy var candidatePreviewPipeline = CandidatePipeline.preview { [weak self] result in
        self?.receiveCandidates(result)
    }
    private var selection = CandidateSelection()
    private var candidateAnchor = CandidateAnchor()
    private var explicitlyNavigated = false
    private lazy var candidatePanel: CandidatePanel = {
        let panel = CandidatePanel()
        panel.list.onSelect = { [weak self] id in
            guard let self, let client = self.client(),
                  self.session.pendingCandidateRequest == nil,
                  let candidate = self.session.candidates.first(where: { $0.id == id }) else { return }
            self.commitCandidate(candidate, to: client)
        }
        panel.list.onMovePage = { [weak self] offset in
            guard let self else { return }
            self.moveCandidateSelection(by: offset * self.selection.visiblePageSize)
        }
        panel.list.onToggleExpansion = { [weak self] in
            guard let self, self.session.pendingCandidateRequest == nil, let client = self.client() else { return }
            self.selection.setExpanded(!self.selection.isExpanded)
            self.presentCandidates(to: client)
        }
        return panel
    }()

    // InputMethodKit's Objective-C callbacks have no actor annotations. Its UI callbacks
    // arrive on the main thread; bridge that boundary explicitly for Swift 6.
    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        nonisolated(unsafe) let mainEvent = event
        nonisolated(unsafe) let mainClient = sender
        return MainActor.assumeIsolated { handleOnMain(mainEvent, client: mainClient) }
    }

    private func handleOnMain(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown, let client = sender as? any IMKTextInput else { return false }
        let previousCandidates = session.candidates
        let previousRequest = session.pendingCandidateRequest?.id
        configureSession()
        if previousCandidates != session.candidates || previousRequest != session.pendingCandidateRequest?.id { update(client) }

        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            commitLiteral(to: client)
            return false
        }

        if !session.buffer.isEmpty,
           let action = CandidateSelection.action(keyCode: event.keyCode, characters: event.characters,
                                                  pageSize: selection.visiblePageSize) {
            resolveCandidates(to: client)
            switch action {
            case .move(let distance): moveCandidateSelection(by: distance, to: client)
            case .choose(let number): commitCandidate(selection.candidate(number: number), to: client)
            }
            return true
        }

        switch event.keyCode {
        case 51: // Delete
            guard !session.buffer.isEmpty else { session.breakContext(); return false }
            session.deleteBackward()
            update(client)
            return true
        case 117: // Forward Delete
            guard !session.buffer.isEmpty else { session.breakContext(); return false }
            session.deleteForward()
            update(client)
            return true
        case 53: // Escape
            guard !session.buffer.isEmpty else { session.breakContext(); return false }
            session.reset()
            update(client)
            return true
        case 36, 76: // Return / keypad Enter: preserve the original spelling.
            guard !session.buffer.isEmpty else { session.breakContext(); return false }
            commitLiteral(to: client)
            return true
        case 49: // Space
            guard !session.buffer.isEmpty else { return false }
            resolveCandidates(to: client)
            let selected = currentCandidate
            let commit = session.commitResult(selected, reason: explicitlyNavigated ? .explicitSelection : .defaultAcceptance)
            let suffix = commit.remainingInput.isEmpty && selected?.appendsSpaceOnAcceptance != false ? " " : ""
            apply(commit, suffix: suffix, to: client)
            PersonalizationSettings.shared.record(commit)
            return true
        case 123, 124: // Edit the marked composition without moving the host-document caret.
            guard !session.buffer.isEmpty else { session.breakContext(); return false }
            session.moveCursor(by: event.keyCode == 123 ? -1 : 1)
            update(client)
            return true
        case 115, 119: // Home / End
            guard !session.buffer.isEmpty else { session.breakContext(); return false }
            if event.keyCode == 115 { session.moveToStart() } else { session.moveToEnd() }
            update(client)
            return true
        case 125, 126, 116, 121: // Navigation outside composition belongs to the host.
            session.breakContext()
            return false
        default:
            break
        }

        guard let text = event.characters, !text.isEmpty else { return false }
        if text.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) && $0.isASCII })
            || (text == "'" && !session.buffer.isEmpty) {
            session.append(text)
            update(client)
            return true
        }
        resolveCandidates(to: client)
        let selected = currentCandidate
        let boundary = CompositionBoundary.resolve(text: text, selected: selected, explicitlySelected: explicitlyNavigated,
                                                   behavior: LanguageSettings.shared.punctuationBehavior)
        if let candidate = boundary.candidate {
            let commit = session.commitResult(candidate, reason: .passthrough)
            apply(commit, suffix: boundary.replacement ?? "", to: client)
            session.breakContext()
            return boundary.replacement != nil
        }
        commitLiteral(to: client)
        return false
    }

    private func commitCandidate(_ candidate: InputCandidate?, to client: any IMKTextInput) {
        guard let candidate, session.candidates.contains(candidate) else { return }
        let commit = session.commitResult(candidate, reason: .explicitSelection)
        apply(commit, to: client)
        PersonalizationSettings.shared.record(commit)
    }

    private func configureSession() {
        session.configure(languages: LanguageSettings.shared.enabledLanguages,
                          learning: PersonalizationSettings.shared.rankingProfile,
                          dictionary: UserDictionarySettings.shared.dictionaryForInput,
                          usesContext: PersonalizationSettings.shared.usesContext,
                          contextGeneration: PersonalizationSettings.shared.contextGeneration)
    }

    private func receiveCandidates(_ result: CandidateResult) {
        guard let client = candidateClient else { return }
        let previousRequest = session.pendingCandidateRequest?.id
        // Consent, secure input, language, dictionary, and context may change while work is running.
        configureSession()
        if session.accept(result) {
            update(client)
        } else if previousRequest != session.pendingCandidateRequest?.id {
            update(client)
        }
    }

    private func resolveCandidates(to client: any IMKTextInput) {
        guard session.pendingCandidateRequest != nil else { return }
        session.resolveCandidates()
        update(client)
    }

    private var currentCandidate: InputCandidate? {
        selection.selected
    }

    private func moveCandidateSelection(by distance: Int, to eventClient: (any IMKTextInput)? = nil) {
        guard !session.buffer.isEmpty, let client = eventClient ?? client() else { return }
        selection.move(by: distance)
        explicitlyNavigated = true
        presentCandidates(to: client)
    }

    private func presentCandidates(to client: any IMKTextInput) {
        let screens = NSScreen.screens.map { CandidatePlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let caret = candidateAnchor.resolve(cursorUTF16Offset: session.cursorUTF16Offset, screens: screens) { index in
            var rect = NSRect.zero
            // The SDK specifies inline-session-relative UTF-16 indexes, not document offsets.
            _ = client.attributes(forCharacterIndex: index, lineHeightRectangle: &rect)
            return rect
        }
        guard let caret else { candidatePanel.orderOut(nil); return }
        candidatePanel.show(selection: selection, caret: caret, clientLevel: Int(client.windowLevel()), screens: screens,
                            isPending: session.pendingCandidateRequest != nil, refreshPendingRows: session.hasCandidatePreview)
    }

    nonisolated override func commitComposition(_ sender: Any!) {
        nonisolated(unsafe) let mainClient = sender
        MainActor.assumeIsolated {
            guard let client = mainClient as? any IMKTextInput ?? client() else { return }
            commitLiteral(to: client)
        }
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        MainActor.assumeIsolated {
            session.breakContext()
            candidatePipeline.invalidate()
            candidatePreviewPipeline.invalidate()
            candidateClient = nil
            candidateAnchor.reset()
            candidatePanel.orderOut(nil)
        }
        super.deactivateServer(sender)
    }

    nonisolated override func menu() -> NSMenu! {
        let menu = NSMenu(title: "SI")
        menu.addItem(withTitle: "SI Settings…", action: #selector(showPreferences(_:)), keyEquivalent: "")
        return menu
    }

    nonisolated override func showPreferences(_ sender: Any!) {
        MainActor.assumeIsolated {
            (NSApplication.shared.delegate as? AppDelegate)?.showSettings()
        }
    }

    private func update(_ client: any IMKTextInput) {
        candidateClient = client
        let rankingTime = Date.now
        selection.update(session.candidates, prefixScore: { self.session.presentationScore(for: $0, now: rankingTime) })
        explicitlyNavigated = false
        client.setMarkedText(session.buffer, selectionRange: NSRange(location: session.cursorUTF16Offset, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        if session.buffer.isEmpty {
            candidatePipeline.invalidate()
            candidatePreviewPipeline.invalidate()
            candidateAnchor.reset()
            candidatePanel.orderOut(nil)
        } else if let request = session.pendingCandidateRequest {
            presentCandidates(to: client)
            if !session.hasCandidatePreview { candidatePreviewPipeline.submit(request) }
            candidatePipeline.submit(request)
        } else {
            candidatePipeline.invalidate()
            candidatePreviewPipeline.invalidate()
            presentCandidates(to: client)
        }
    }

    private func commitLiteral(to client: any IMKTextInput) {
        defer { session.breakContext() }
        guard !session.buffer.isEmpty else { return }
        insert(session.commit(), into: client)
    }

    private func insert(_ text: String, into client: any IMKTextInput) {
        candidatePipeline.invalidate()
        candidatePreviewPipeline.invalidate()
        candidateClient = nil
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        selection.update([])
        candidateAnchor.reset()
        explicitlyNavigated = false
        candidatePanel.orderOut(nil)
    }

    private func apply(_ commit: InputCommit, suffix: String = "", to client: any IMKTextInput) {
        insert(commit.text + suffix, into: client)
        if !session.buffer.isEmpty { update(client) }
    }
}
