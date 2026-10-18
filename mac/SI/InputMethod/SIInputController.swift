import AppKit
import InputMethodKit

// InputMethodKit resolves this stable Objective-C name from Info.plist.
@MainActor
@objc(SIInputController)
// The legacy superclass is not Sendable. All mutable state remains main-actor isolated.
final class SIInputController: IMKInputController, @unchecked Sendable {
    private var session = InputSession()
    private var selectedText: String?
    private lazy var candidatePanel: IMKCandidates? = {
        let panel = IMKCandidates(server: server(), panelType: kIMKSingleColumnScrollingCandidatePanel)
        panel?.setAttributes([IMKCandidatesSendServerKeyEventFirst as String: true])
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
        session.configure(languages: LanguageSettings.shared.enabledLanguages)

        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            commitLiteral(to: client)
            return false
        }

        switch event.keyCode {
        case 51: // Delete
            guard !session.buffer.isEmpty else { return false }
            session.deleteBackward()
            update(client)
            return true
        case 53: // Escape
            guard !session.buffer.isEmpty else { return false }
            session.reset()
            update(client)
            return true
        case 36, 76: // Return / keypad Enter: preserve the original spelling.
            guard !session.buffer.isEmpty else { return false }
            commitLiteral(to: client)
            return true
        case 49: // Space
            guard !session.buffer.isEmpty else { return false }
            let selected = session.candidates.first { candidateTitle(for: $0) == selectedText } ?? session.candidates.first
            let suffix = selected?.language == .simplifiedChinese ? "" : " "
            insert(session.commit(selected) + suffix, into: client)
            return true
        case 123, 124, 125, 126: // Let the native candidate window navigate its selection.
            guard !session.buffer.isEmpty else { return false }
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
        // Native candidate selection keys are 1–9. Outside composition they pass through.
        if !session.buffer.isEmpty, text.count == 1, "123456789".contains(text) {
            return false
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
        guard let text = selected,
              let candidate = session.candidates.first(where: { candidateTitle(for: $0) == text }),
              let client = client() else { return }
        insert(session.commit(candidate), into: client)
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
        MainActor.assumeIsolated { candidatePanel?.hide() }
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
        client.setMarkedText(session.buffer, selectionRange: NSRange(location: session.buffer.utf16.count, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        if session.buffer.isEmpty {
            candidatePanel?.hide()
        } else {
            candidatePanel?.update()
            candidatePanel?.show(kIMKLocateCandidatesBelowHint)
        }
    }

    private func commitLiteral(to client: any IMKTextInput) {
        guard !session.buffer.isEmpty else { return }
        insert(session.commit(), into: client)
    }

    private func insert(_ text: String, into client: any IMKTextInput) {
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        selectedText = nil
        candidatePanel?.hide()
    }
}
