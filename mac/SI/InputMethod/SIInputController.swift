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
    private var historyDraft = InputHistoryDraft()
    private var historyExpirationTask: Task<Void, Never>?
    private var historyActivityRevision: UInt64 = 0
    private var historyExpectedLocation: Int?
    private var memoryGeneration: UInt64?
    private var memoryLanguageGeneration: UInt64?
    private var historyWasEnabled: Bool?
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
            self.moveCandidateSelection(by: offset * self.selection.visiblePageSize)
        }
        panel.list.onToggleExpansion = { [weak self] in
            guard let self, self.candidatePanel.ownsPresentation,
                  self.session.pendingCandidateRequest == nil, let client = self.client() else { return }
            self.session.suspendAutomaticConfirmation()
            self.automaticConfirmationTask?.cancel()
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
        candidatePanel.claimPresentation()
        let previousCandidates = session.candidates
        let previousRequest = session.pendingCandidateRequest?.id
        configureSession(for: client)
        checkHistoryPosition(in: client)
        if previousCandidates != session.candidates || previousRequest != session.pendingCandidateRequest?.id { update(client) }

        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            invalidateHistory()
            commitLiteral(to: client)
            return false
        }

        if !session.buffer.isEmpty,
           let action = CandidateSelection.action(keyCode: event.keyCode, characters: event.characters,
                                                  pageSize: selection.visiblePageSize, isExpanded: selection.isExpanded) {
            resolveCandidates(to: client)
            switch action {
            case .move(let distance): moveCandidateSelection(by: distance, to: client)
            case .choose(let number): commitCandidate(selection.candidate(number: number), to: client)
            }
            return true
        }

        switch event.keyCode {
        case 51: // Delete
            guard !session.buffer.isEmpty else { invalidateHistory(); session.breakContext(); return false }
            session.deleteBackward()
            update(client)
            return true
        case 117: // Forward Delete
            guard !session.buffer.isEmpty else { invalidateHistory(); session.breakContext(); return false }
            session.deleteForward()
            update(client)
            return true
        case 53: // Escape
            invalidateHistory()
            guard !session.buffer.isEmpty else { session.breakContext(); return false }
            session.reset()
            update(client)
            return true
        case 36, 76: // Return / keypad Enter: preserve the original spelling.
            guard !session.buffer.isEmpty else {
                if event.modifierFlags.contains(.shift) { invalidateHistory() }
                else { finishHistory() }
                session.breakContext()
                return false
            }
            commitLiteral(to: client)
            return true
        case 49: // Space
            guard !session.buffer.isEmpty else { appendHistoryPassthrough(" ", in: client); return false }
            resolveCandidates(to: client)
            let selected = currentCandidate
            let commit = session.commitResult(selected, reason: explicitlyNavigated ? .explicitSelection : .defaultAcceptance)
            let suffix = commit.remainingInput.isEmpty && selected?.appendsSpaceOnAcceptance != false ? " " : ""
            apply(commit, suffix: suffix, to: client)
            return true
        case 123, 124: // Edit the marked composition without moving the host-document caret.
            guard !session.buffer.isEmpty else { invalidateHistory(); session.breakContext(); return false }
            session.moveCursor(by: event.keyCode == 123 ? -1 : 1)
            update(client)
            return true
        case 115, 119: // Home / End
            guard !session.buffer.isEmpty else { invalidateHistory(); session.breakContext(); return false }
            if event.keyCode == 115 { session.moveToStart() } else { session.moveToEnd() }
            update(client)
            return true
        case 125, 126, 116, 121: // Navigation outside composition belongs to the host.
            invalidateHistory()
            session.breakContext()
            return false
        default:
            break
        }

        guard let text = event.characters, !text.isEmpty else { invalidateHistory(); return false }
        if text.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) && $0.isASCII })
            || (text == "'" && !session.buffer.isEmpty) {
            session.append(text)
            update(client)
            return true
        }
        let punctuation = LanguageSettings.shared.punctuationBehavior
        if session.buffer.isEmpty, !LanguageSettings.shared.enabledLanguages.isEmpty,
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
            if boundary.replacement == nil { appendHistoryPassthrough(text, in: client) }
            return boundary.replacement != nil
        }
        if !session.buffer.isEmpty, boundary.continuesComposition {
            session.append(text)
            update(client)
            return true
        }
        commitLiteral(to: client)
        appendHistoryPassthrough(text, in: client)
        return false
    }

    private func commitCandidate(_ candidate: InputCandidate?, to client: any IMKTextInput) {
        guard let candidate else { return }
        // Mouse selection can arrive after consent, deletion or secure-input changes without a key event.
        configureSession(for: client)
        resolveCandidates(to: client)
        guard let current = session.candidates.first(where: {
            $0.id == candidate.id && $0.text.utf8.elementsEqual(candidate.text.utf8)
                && ($0.historyInput ?? "").utf8.elementsEqual((candidate.historyInput ?? "").utf8)
        }) else { update(client); return }
        let commit = session.commitResult(current, reason: .explicitSelection)
        apply(commit, to: client)
    }

    private func configureSession(for eventClient: (any IMKTextInput)? = nil) {
        if let client = eventClient ?? client() { prepareApplicationMemory(for: client) }
        let appSettings = ApplicationMemorySettings.shared
        var memory = applicationID.map { appSettings.snapshot(for: $0) } ?? .empty
        memory.historyPrefix = historyDraft
        session.configure(languages: LanguageSettings.shared.enabledLanguages,
                          learning: memory.learning,
                          dictionary: UserDictionarySettings.shared.dictionaryForInput,
                          contextGeneration: sessionContextGeneration,
                          automaticConfirmationEnabled: LanguageSettings.shared.automaticConfirmationEnabled
                            && !IsSecureEventInputEnabled(),
                          configurationGeneration: LanguageSettings.shared.configurationGeneration,
                          applicationMemory: memory)
    }

    private func prepareApplicationMemory(for client: any IMKTextInput) {
        let sameClient = memoryClient.map { ($0 as AnyObject) === (client as AnyObject) } ?? false
        if !sameClient {
            let identifier = client.bundleIdentifier()
            memoryClient = client
            applicationID = identifier.flatMap { $0.isEmpty ? nil : $0 }
            resetHistory()
            memoryGeneration = nil
            sessionContextGeneration &+= 1
        }
        let settings = ApplicationMemorySettings.shared
        let enabled = applicationID.map { settings.usesHistory(in: $0) } ?? false
        let languageGeneration = LanguageSettings.shared.configurationGeneration
        if let memoryGeneration,
           memoryGeneration != settings.generation || historyWasEnabled != enabled || memoryLanguageGeneration != languageGeneration {
            if !historyDraft.text.isEmpty || !session.buffer.isEmpty { invalidateHistory() }
            else { resetHistory() }
            sessionContextGeneration &+= 1
        }
        memoryGeneration = settings.generation
        memoryLanguageGeneration = languageGeneration
        historyWasEnabled = enabled
        historyDraft.expire()
        if !enabled { invalidateHistory() }
    }

    private func invalidateHistory() {
        historyExpirationTask?.cancel()
        historyExpirationTask = nil
        historyActivityRevision &+= 1
        historyDraft.invalidate()
        historyExpectedLocation = nil
    }

    private func resetHistory() {
        invalidateHistory()
        historyDraft = InputHistoryDraft()
    }

    private func scheduleHistoryExpiration() {
        historyExpirationTask?.cancel()
        guard !historyDraft.isInvalid, !historyDraft.text.isEmpty else { return }
        historyActivityRevision &+= 1
        let activity = historyActivityRevision
        historyExpirationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(InputHistoryDraft.lifetime)) } catch { return }
            guard !Task.isCancelled, let self, self.historyActivityRevision == activity else { return }
            self.invalidateHistory()
            guard self.candidatePanel.ownsPresentation, let client = self.memoryClient, let current = self.client(),
                  (client as AnyObject) === (current as AnyObject) else { return }
            self.configureSession(for: client)
            if !self.session.buffer.isEmpty { self.update(client) }
        }
    }

    private func checkHistoryPosition(in client: any IMKTextInput) {
        guard session.buffer.isEmpty, !historyDraft.text.isEmpty, let expected = historyExpectedLocation else { return }
        let revision = presentationRevision
        let range = client.selectedRange()
        guard revision == presentationRevision else { invalidateHistory(); return }
        if range.location != NSNotFound && (range.length != 0 || range.location != expected) { invalidateHistory() }
    }

    private func rememberHistoryPosition(in client: any IMKTextInput, adding count: Int = 0) {
        guard !historyDraft.isInvalid, !historyDraft.text.isEmpty else { return }
        let revision = presentationRevision
        let range = client.selectedRange()
        guard revision == presentationRevision else { invalidateHistory(); return }
        historyExpectedLocation = range.location != NSNotFound && range.length == 0 && range.location <= Int.max - count
            ? range.location + count : nil
    }

    private func appendHistoryPassthrough(_ text: String, in client: any IMKTextInput) {
        guard let applicationID, ApplicationMemorySettings.shared.usesHistory(in: applicationID) else { return }
        guard !text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value)
        }) else { invalidateHistory(); return }
        historyDraft.append(input: text, text: text)
        scheduleHistoryExpiration()
        // The event is still passed through exactly once; verify its expected caret position next time.
        rememberHistoryPosition(in: client, adding: text.utf16.count)
    }

    private func finishHistory() {
        defer { resetHistory() }
        guard let applicationID, ApplicationMemorySettings.shared.usesHistory(in: applicationID),
              let entry = historyDraft.entry(applicationID: applicationID) else { return }
        ApplicationMemorySettings.shared.recordHistory(entry)
    }

    private func receiveCandidates(_ result: CandidateResult) {
        guard candidatePanel.ownsPresentation, let client = candidateClient, let activeClient = self.client(),
              (client as AnyObject) === (activeClient as AnyObject) else { return }
        let previousRequest = session.pendingCandidateRequest?.id
        // Consent, secure input, language, dictionary, and context may change while work is running.
        configureSession()
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

    private func moveCandidateSelection(by distance: Int, to eventClient: (any IMKTextInput)? = nil) {
        guard !session.buffer.isEmpty, let client = eventClient ?? client() else { return }
        session.suspendAutomaticConfirmation()
        automaticConfirmationTask?.cancel()
        selection.move(by: distance)
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
            invalidateHistory()
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
            resetHistory()
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
        menu.addItem(withTitle: "SI Settings…", action: #selector(showPreferences(_:)), keyEquivalent: "")
        // IMK dispatches menu selectors here via doCommandBySelector:commandDictionary:.
        let item = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
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
            self.configureSession()
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
        guard insert(commit.text + suffix, into: client) else { invalidateHistory(); return }
        guard app == applicationID, generation == ApplicationMemorySettings.shared.generation else { invalidateHistory(); return }
        if let app {
            ApplicationMemorySettings.shared.recordVocabulary(commit, applicationID: app)
            if ApplicationMemorySettings.shared.usesHistory(in: app) {
                historyDraft.append(commit, suffix: suffix)
                scheduleHistoryExpiration()
                rememberHistoryPosition(in: client)
            }
        }
        configureSession(for: client)
        if !session.buffer.isEmpty { update(client) }
    }
}
