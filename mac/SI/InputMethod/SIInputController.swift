import AppKit
import InputMethodKit

// InputMethodKit resolves this stable Objective-C name from Info.plist.
@MainActor
@objc(SIInputController)
// The legacy superclass is not Sendable. All mutable state remains main-actor isolated.
final class SIInputController: IMKInputController, @unchecked Sendable {
    private var session = InputSession()
    private var selectedText: String?
    private var explicitlyNavigated = false
    private lazy var candidatePanel: IMKCandidates? = {
        let panel = IMKCandidates(server: server(), panelType: kIMKSingleColumnScrollingCandidatePanel)
        panel?.setAttributes([IMKCandidatesSendServerKeyEventFirst as String: NSNumber(value: true)])
        panel?.setSelectionKeys([18, 19, 20, 21, 23, 22, 26, 28, 25].map { NSNumber(value: $0) })
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
        session.configure(languages: LanguageSettings.shared.enabledLanguages,
                          learning: PersonalizationSettings.shared.rankingProfile,
                          dictionary: UserDictionarySettings.shared.dictionaryForInput,
                          usesContext: PersonalizationSettings.shared.usesContext,
                          contextGeneration: PersonalizationSettings.shared.contextGeneration)
        if previousCandidates != session.candidates { update(client) }

        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            commitLiteral(to: client)
            return false
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
        case 125, 126, 116, 121: // Explicit selection; returning false is not a navigation command.
            guard !session.buffer.isEmpty else { session.breakContext(); return false }
            let pageSize = candidatePanel?.selectionKeys()?.count ?? 9
            let distance = event.keyCode == 116 || event.keyCode == 121 ? pageSize : 1
            moveCandidateSelection(by: event.keyCode == 126 || event.keyCode == 116 ? -distance : distance)
            return true
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
        // Resolve the native window's visible row, including its current scroll position.
        if !session.buffer.isEmpty, text.count == 1, "123456789".contains(text), let number = Int(text) {
            selectCandidate(atVisibleLine: number - 1, to: client)
            return true
        }
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

    nonisolated override func candidates(_ sender: Any!) -> [Any]! {
        let strings = MainActor.assumeIsolated { session.candidates.map { candidateTitle(for: $0) } }
        return strings
    }

    nonisolated override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        let text = candidateString?.string
        MainActor.assumeIsolated {
            selectedText = text
        }
    }

    nonisolated override func candidateSelected(_ candidateString: NSAttributedString!) {
        let text = candidateString?.string
        MainActor.assumeIsolated { selectCandidateOnMain(text) }
    }

    private func selectCandidateOnMain(_ selected: String?) {
        guard let client = client() else { return }
        commitCandidate(named: selected, to: client)
    }

    private func commitCandidate(named title: String?, to client: any IMKTextInput) {
        guard let title,
              let candidate = session.candidates.first(where: { candidateTitle(for: $0) == title }) else { return }
        let commit = session.commitResult(candidate, reason: .explicitSelection)
        apply(commit, to: client)
        PersonalizationSettings.shared.record(commit)
    }

    private var currentCandidate: InputCandidate? {
        guard !session.buffer.isEmpty else { return nil }
        let title = selectedText ?? candidatePanel?.selectedCandidateString()?.string
        return session.candidates.first { candidateTitle(for: $0) == title } ?? session.candidates.first
    }

    private func moveCandidateSelection(by distance: Int) {
        guard let panel = candidatePanel, let current = currentCandidate,
              let index = session.candidates.firstIndex(where: { $0.id == current.id }) else { return }
        let next = max(0, min(session.candidates.count - 1, index + distance))
        let title = candidateTitle(for: session.candidates[next])
        let identifier = panel.candidateStringIdentifier(title)
        guard identifier != NSNotFound, panel.selectCandidate(withIdentifier: identifier) else { return }
        selectedText = title
        explicitlyNavigated = true
    }

    private func selectCandidate(atVisibleLine line: Int, to client: any IMKTextInput) {
        guard let panel = candidatePanel, panel.isVisible() else { return }
        let identifier = panel.candidateIdentifier(atLineNumber: line)
        guard identifier != NSNotFound, panel.selectCandidate(withIdentifier: identifier) else { return }
        commitCandidate(named: panel.selectedCandidateString()?.string, to: client)
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
            candidatePanel?.hide()
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

    private func candidateTitle(for candidate: InputCandidate) -> String {
        "\(candidate.text)    \(candidate.label)"
    }

    private func update(_ client: any IMKTextInput) {
        selectedText = nil
        explicitlyNavigated = false
        client.setMarkedText(session.buffer, selectionRange: NSRange(location: session.cursorUTF16Offset, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        if session.buffer.isEmpty {
            candidatePanel?.hide()
        } else {
            candidatePanel?.update()
            candidatePanel?.show(kIMKLocateCandidatesBelowHint)
        }
    }

    private func commitLiteral(to client: any IMKTextInput) {
        defer { session.breakContext() }
        guard !session.buffer.isEmpty else { return }
        insert(session.commit(), into: client)
    }

    private func insert(_ text: String, into client: any IMKTextInput) {
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        selectedText = nil
        explicitlyNavigated = false
        candidatePanel?.hide()
    }

    private func apply(_ commit: InputCommit, suffix: String = "", to client: any IMKTextInput) {
        insert(commit.text + suffix, into: client)
        if !session.buffer.isEmpty { update(client) }
    }
}
