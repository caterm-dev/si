import AppKit
import InputMethodKit
import Carbon

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
    private var markedTextState = MarkedTextState()
    private var presentationRevision: UInt64 = 0
    private var candidateAnchor = CandidateAnchor()
    private var explicitlyNavigated = false
    private var automaticConfirmationTask: Task<Void, Never>?
    private weak var memoryClient: (any IMKTextInput)?
    private var applicationID: String?
    private var memoryGeneration: UInt64?
    private var memoryLanguageGeneration: UInt64?
    private var sessionContextGeneration: UInt64 = 0
    private lazy var candidatePanel: CandidatePanel = {
        let panel = CandidatePanel()
        panel.list.onSelect = { [weak self] id in
            guard let self, self.candidatePanel.ownsPresentation, let client = self.client(),
                  self.session.pendingCandidateRequest == nil,
                  let candidate = self.session.candidates.first(where: { $0.id == id }) else { return }
            self.commitCandidate(candidate, to: client)
        }
        panel.list.onMovePage = { [weak self] offset in
            guard let self, self.candidatePanel.ownsPresentation else { return }
            self.moveCandidateSelection(.page(offset))
        }
        panel.list.onToggleExpansion = { [weak self] in
            guard let self, self.candidatePanel.ownsPresentation,
                  self.session.pendingCandidateRequest == nil, let client = self.client() else { return }
            guard self.configureSession(for: client) else { return }
            self.setCandidateListExpanded(!self.selection.isExpanded, to: client)
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
        candidatePanel.claimPresentation()
        let previousCandidates = session.candidates
        let previousRequest = session.pendingCandidateRequest?.id
        guard configureSession(for: client) else { return false }
        if previousCandidates != session.candidates || previousRequest != session.pendingCandidateRequest?.id { update(client) }

        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            commitLiteral(to: client)
            return false
        }

        if !session.buffer.isEmpty,
           let action = CandidateSelection.action(keyCode: event.keyCode, characters: event.characters,
                                                  pageSize: selection.visiblePageSize, isExpanded: selection.isExpanded) {
            resolveCandidates(to: client)
            switch action {
            case .expand: setCandidateListExpanded(true, to: client)
            case .navigate(let navigation): moveCandidateSelection(navigation, to: client)
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
            guard !session.buffer.isEmpty else {
                session.breakContext()
                return false
            }
            commitLiteral(to: client)
            return true
        case 49: // Space
            guard !session.buffer.isEmpty else { return false }
            resolveCandidates(to: client)
            let selected = currentCandidate
            let commit = session.commitResult(selected, reason: selection.confirmationReason(for: selected))
            let suffix = commit.remainingInput.isEmpty && selected?.appendsSpaceOnAcceptance != false ? " " : ""
            apply(commit, suffix: suffix, to: client)
            return true
        case 115, 119: // Home / End
            guard !session.buffer.isEmpty else { session.breakContext(); return false }
            if event.keyCode == 115 { session.moveToStart() } else { session.moveToEnd() }
            update(client)
            return true
        case 123, 124, 125, 126, 116, 121: // Navigation outside composition belongs to the host.
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
        let punctuation = LanguageSettings.shared.punctuationBehavior
        if session.buffer.isEmpty, LanguageSettings.shared.punctuationCandidatesEnabled,
           !LanguageSettings.shared.enabledLanguages.isEmpty,
           PunctuationCandidates.recognizes(text) {
            session.append(text)
            update(client)
            return true
        }
        if !session.buffer.isEmpty, CompositionBoundary.keepsInComposition(text: text, behavior: punctuation) {
            session.append(text)
            update(client)
            return true
        }
        resolveCandidates(to: client)
        let selected = currentCandidate
        let boundary = CompositionBoundary.resolve(text: text, selected: selected, explicitlySelected: explicitlyNavigated,
                                                   behavior: punctuation)
        if let candidate = boundary.candidate {
            let commit = session.commitResult(candidate, reason: .passthrough)
            apply(commit, suffix: boundary.replacement ?? "", to: client)
            session.breakContext()
            return boundary.replacement != nil
        }
        if !session.buffer.isEmpty, boundary.continuesComposition {
            session.append(text)
            update(client)
            return true
        }
        commitLiteral(to: client)
        return false
    }

    private func commitCandidate(_ candidate: InputCandidate?, to client: any IMKTextInput) {
        guard let candidate else { return }
        // Mouse selection can arrive after consent, deletion or secure-input changes without a key event.
        guard configureSession(for: client) else { return }
        resolveCandidates(to: client)
        guard let current = session.candidates.first(where: {
            $0.id == candidate.id && $0.text.utf8.elementsEqual(candidate.text.utf8)
        }) else { update(client); return }
        let commit = session.commitResult(current, reason: selection.confirmationReason(for: current))
        apply(commit, to: client)
    }

    /// False means this client uses direct input. Check at every delayed commit boundary too.
    @discardableResult
    private func configureSession(for eventClient: (any IMKTextInput)? = nil) -> Bool {
        if let client = eventClient ?? client() {
            prepareApplicationMemory(for: client)
            if LanguageSettings.shared.usesPassthrough(in: applicationID) {
                stopConversionForDirectInput(in: client)
                return false
            }
        }
        let appSettings = ApplicationMemorySettings.shared
        let memory = applicationID.map { appSettings.snapshot(for: $0) } ?? .empty
        session.configure(languages: LanguageSettings.shared.enabledLanguages,
                          learning: memory.learning,
                          dictionary: UserDictionarySettings.shared.dictionaryForInput,
                          contextGeneration: sessionContextGeneration,
                          automaticConfirmationEnabled: LanguageSettings.shared.automaticConfirmationEnabled
                            && !IsSecureEventInputEnabled(),
                          configurationGeneration: LanguageSettings.shared.configurationGeneration,
                          applicationMemory: memory,
                          punctuationCandidatesEnabled: LanguageSettings.shared.punctuationCandidatesEnabled)
        return true
    }

    private func stopConversionForDirectInput(in client: any IMKTextInput) {
        let spelling = session.buffer
        session.reset()
        automaticConfirmationTask?.cancel()
        candidatePipeline.invalidate()
        candidatePreviewPipeline.invalidate()
        candidateClient = nil
        selection.update([])
        explicitlyNavigated = false
        candidateAnchor.reset()
        markedTextState.reset()
        // Preserve only the pending spelling, once, without learning or a space.
        if !spelling.isEmpty { insert(spelling, into: client) }
        else { candidatePanel.orderOut(nil) }
    }

    private func prepareApplicationMemory(for client: any IMKTextInput) {
        let sameClient = memoryClient.map { ($0 as AnyObject) === (client as AnyObject) } ?? false
        if !sameClient {
            let identifier = client.bundleIdentifier()
            memoryClient = client
            applicationID = identifier.flatMap { $0.isEmpty ? nil : $0 }
            memoryGeneration = nil
            sessionContextGeneration &+= 1
        }
        let settings = ApplicationMemorySettings.shared
        let languageGeneration = LanguageSettings.shared.configurationGeneration
        if let memoryGeneration,
           memoryGeneration != settings.generation || memoryLanguageGeneration != languageGeneration {
            sessionContextGeneration &+= 1
        }
        memoryGeneration = settings.generation
        memoryLanguageGeneration = languageGeneration
    }

    private func receiveCandidates(_ result: CandidateResult) {
        guard candidatePanel.ownsPresentation, let client = candidateClient, let activeClient = self.client(),
              (client as AnyObject) === (activeClient as AnyObject) else { return }
        let previousRequest = session.pendingCandidateRequest?.id
        // Consent, secure input, language, dictionary, and context may change while work is running.
        guard configureSession() else { return }
        if session.accept(result) {
            if let commit = session.automaticallyConfirm() {
                apply(commit, to: client)
            } else {
                update(client)
            }
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

    private func setCandidateListExpanded(_ expanded: Bool, to client: any IMKTextInput) {
        guard !session.buffer.isEmpty, candidatePanel.ownsPresentation else { return }
        session.suspendAutomaticConfirmation()
        automaticConfirmationTask?.cancel()
        selection.setExpanded(expanded)
        presentCandidates(to: client)
    }

    private func moveCandidateSelection(_ navigation: CandidateSelection.Navigation, to eventClient: (any IMKTextInput)? = nil) {
        guard !session.buffer.isEmpty, let client = eventClient ?? client() else { return }
        guard configureSession(for: client) else { return }
        session.suspendAutomaticConfirmation()
        automaticConfirmationTask?.cancel()
        selection.navigate(navigation)
        explicitlyNavigated = true
        presentCandidates(to: client)
    }

    private func presentCandidates(to client: any IMKTextInput) {
        guard candidatePanel.ownsPresentation else { return }
        let revision = presentationRevision
        let screens = NSScreen.screens.map { CandidatePlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        // Host geometry calls can synchronously service another IMK event. Resolve on
        // a value copy so reentry cannot overlap a mutating access to controller state.
        var nextAnchor = candidateAnchor
        let caret = nextAnchor.resolve(cursorUTF16Offset: session.cursorUTF16Offset, markedRange: client.markedRange(),
                                             screens: screens, queryRange: { range in
            var actualRange = NSRange(location: NSNotFound, length: 0)
            let rect = client.firstRect(forCharacterRange: range, actualRange: &actualRange)
            return CandidateAnchor.documentRect(rect, actualRange: actualRange, requestedRange: range)
        }) { index in
            var rect = NSRect.zero
            // The SDK specifies inline-session-relative UTF-16 indexes, not document offsets.
            _ = client.attributes(forCharacterIndex: index, lineHeightRectangle: &rect)
            return rect
        }
        let clientLevel = Int(client.windowLevel())
        guard revision == presentationRevision, candidatePanel.ownsPresentation else { return }
        candidateAnchor = nextAnchor
        guard let caret else { candidatePanel.orderOut(nil); return }
        candidatePanel.show(selection: selection, caret: caret, clientLevel: clientLevel, screens: screens,
                            isPending: session.pendingCandidateRequest != nil, refreshPendingRows: session.hasCandidatePreview)
    }

    nonisolated override func commitComposition(_ sender: Any!) {
        nonisolated(unsafe) let mainClient = sender
        MainActor.assumeIsolated {
            guard let client = mainClient as? any IMKTextInput ?? client() else { return }
            guard configureSession(for: client) else { return }
            commitLiteral(to: client)
        }
    }

    nonisolated override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        MainActor.assumeIsolated {
            presentationRevision &+= 1
            candidateAnchor.reset()
            markedTextState.reset()
            memoryClient = nil
            applicationID = nil
            candidatePanel.claimPresentation()
        }
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        MainActor.assumeIsolated {
            presentationRevision &+= 1
            session.breakContext()
            automaticConfirmationTask?.cancel()
            candidatePipeline.invalidate()
            candidatePreviewPipeline.invalidate()
            candidateClient = nil
            markedTextState.reset()
            candidateAnchor.reset()
            candidatePanel.releasePresentation()
        }
        super.deactivateServer(sender)
    }

    nonisolated override func menu() -> NSMenu! {
        let menu = NSMenu(title: "SI")
        menu.autoenablesItems = false
        menu.addItem(withTitle: L10n.text("SI Settings…"), action: #selector(showPreferences(_:)), keyEquivalent: "")
        // IMK dispatches menu selectors here via doCommandBySelector:commandDictionary:.
        let item = menu.addItem(withTitle: L10n.text("Check for Updates…"), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.isEnabled = MainActor.assumeIsolated {
            (NSApplication.shared.delegate as? AppDelegate)?.updater.canCheckForUpdates ?? false
        }
        return menu
    }

    @objc nonisolated private func checkForUpdates(_ sender: Any!) {
        // The same main-thread callback assumption as showPreferences; no client data crosses it.
        MainActor.assumeIsolated {
            (NSApplication.shared.delegate as? AppDelegate)?.updater.checkForUpdates()
        }
    }

    nonisolated override func showPreferences(_ sender: Any!) {
        MainActor.assumeIsolated {
            (NSApplication.shared.delegate as? AppDelegate)?.showSettings()
        }
    }

    private func update(_ client: any IMKTextInput) {
        guard candidatePanel.ownsPresentation else { return }
        presentationRevision &+= 1
        let revision = presentationRevision
        automaticConfirmationTask?.cancel()
        let sameClient = candidateClient.map { ($0 as AnyObject) === (client as AnyObject) } ?? false
        if !sameClient {
            markedTextState.reset()
            candidateAnchor.reset()
        }
        candidateClient = client
        selection.update(session.candidates)
        explicitlyNavigated = false
        let markedSelection = NSRange(location: session.cursorUTF16Offset, length: 0)
        if markedTextState.shouldSend(session.buffer, selection: markedSelection) {
            client.setMarkedText(session.buffer, selectionRange: markedSelection,
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        // A nested key, commit or focus callback supersedes this host update.
        guard revision == presentationRevision, candidatePanel.ownsPresentation else { return }
        if session.buffer.isEmpty {
            markedTextState.reset()
            candidatePipeline.invalidate()
            candidatePreviewPipeline.invalidate()
            candidateAnchor.reset()
            candidatePanel.orderOut(nil)
        } else if let request = session.pendingCandidateRequest {
            presentCandidates(to: client)
            guard revision == presentationRevision, candidatePanel.ownsPresentation else { return }
            if !session.hasCandidatePreview { candidatePreviewPipeline.submit(request) }
            candidatePipeline.submit(request)
        } else {
            candidatePipeline.invalidate()
            candidatePreviewPipeline.invalidate()
            presentCandidates(to: client)
            guard revision == presentationRevision, candidatePanel.ownsPresentation else { return }
            scheduleAutomaticConfirmation()
        }
    }

    private func scheduleAutomaticConfirmation() {
        guard session.hasAutomaticPauseCandidate else { return }
        let revision = session.automaticConfirmationRevision
        automaticConfirmationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(InputSession.automaticConfirmationPause)) } catch { return }
            guard !Task.isCancelled, let self,
                  self.candidatePanel.ownsPresentation,
                  self.session.automaticConfirmationRevision == revision,
                  let client = self.candidateClient, let currentClient = self.client(),
                  (client as AnyObject) === (currentClient as AnyObject) else { return }
            // A timer is another commit boundary: recheck settings, secure input and request revision.
            guard self.configureSession() else { return }
            guard self.session.automaticConfirmationRevision == revision else { self.update(client); return }
            guard let commit = self.session.automaticallyConfirm(afterPause: true) else { return }
            self.apply(commit, to: client)
        }
    }

    private func commitLiteral(to client: any IMKTextInput) {
        defer { session.breakContext() }
        guard !session.buffer.isEmpty else { return }
        apply(session.commitResult(reason: .literal), to: client)
    }

    @discardableResult
    private func insert(_ text: String, into client: any IMKTextInput) -> Bool {
        presentationRevision &+= 1
        let revision = presentationRevision
        automaticConfirmationTask?.cancel()
        candidatePipeline.invalidate()
        candidatePreviewPipeline.invalidate()
        candidateClient = nil
        markedTextState.reset()
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        guard revision == presentationRevision else { return false }
        selection.update([])
        candidateAnchor.reset()
        explicitlyNavigated = false
        candidatePanel.orderOut(nil)
        return true
    }

    private func apply(_ commit: InputCommit, suffix: String = "", to client: any IMKTextInput) {
        let app = applicationID
        let generation = ApplicationMemorySettings.shared.generation
        guard insert(commit.text + suffix, into: client) else { return }
        guard app == applicationID, generation == ApplicationMemorySettings.shared.generation else { return }
        guard !LanguageSettings.shared.usesPassthrough(in: app) else {
            configureSession(for: client)
            return
        }
        if let app {
            ApplicationMemorySettings.shared.recordVocabulary(commit, applicationID: app)
        }
        configureSession(for: client)
        if !session.buffer.isEmpty { update(client) }
    }
}
