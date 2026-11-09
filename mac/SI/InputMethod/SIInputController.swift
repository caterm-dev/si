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
    private struct AIPrediction {
        let revision: UInt64
        let settingsGeneration: UInt64
        let languageGeneration: UInt64
        let application: String
        let pid: pid_t
        let candidate: InputCandidate
        let field: AICompletionField?
        let position: AICompletionField.Position?
        let window: AICompletionScreenshot.Window
        let selectionID: String?
        let suffix: String
    }
    private var aiRequestID: UUID?
    private var aiRowPhase: AICompletionActivity.Phase?
    private var aiTask: Task<Void, Never>?
    private var aiPrediction: AIPrediction?
    private var automaticConfirmationTask: Task<Void, Never>?
    private weak var memoryClient: (any IMKTextInput)?
    private var applicationID: String?
    private var memoryGeneration: UInt64?
    private var memoryLanguageGeneration: UInt64?
    private var sessionContextGeneration: UInt64 = 0
    private var sentenceSubmissionGeneration: UInt64?
    private lazy var candidatePanel: CandidatePanel = {
        let panel = CandidatePanel()
        panel.onLosePresentation = { [weak self] in self?.invalidateAICompletion() }
        panel.list.onSelect = { [weak self] id in
            guard let self, self.candidatePanel.ownsPresentation, let client = self.client(),
                  self.session.pendingCandidateRequest == nil,
                  let candidate = self.session.candidates.first(where: { $0.id == id }) else { return }
            guard self.configureSession(for: client), self.session.pendingCandidateRequest == nil else {
                self.update(client)
                return
            }
            self.commitCandidate(candidate, to: client)
        }
        panel.list.onSelectPrediction = { [weak self] in
            guard let self, let client = self.client() else { return }
            _ = self.acceptAICompletion(to: client)
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
        // Check before the passthrough guard so the shortcut can restore conversion too.
        if LanguageSettings.shared.directInputShortcut.matches(keyCode: event.keyCode, modifiers: event.modifierFlags),
           !IsSecureEventInputEnabled(), let identifier = client.bundleIdentifier(), !identifier.isEmpty {
            if !event.isARepeat {
                prepareApplicationMemory(for: client)
                LanguageSettings.shared.togglePassthrough(for: identifier)
                _ = configureSession(for: client)
                session.breakContext()
                sentenceSubmissionGeneration = nil
            }
            return true
        }
        candidatePanel.claimPresentation()
        let previousCandidates = session.candidates
        let previousRequest = session.pendingCandidateRequest?.id
        guard configureSession(for: client) else { return false }
        if sentenceSubmissionGeneration != nil, IsSecureEventInputEnabled() { sentenceSubmissionGeneration = nil }
        if previousCandidates != session.candidates || previousRequest != session.pendingCandidateRequest?.id { update(client) }

        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            commitLiteral(to: client)
            return false
        }

        if let action = AICompletionTabAction.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags,
            isRepeat: event.isARepeat, enabled: AICompletionSettings.shared.enabled,
            composing: !session.buffer.isEmpty, hasSuggestion: aiPrediction != nil, pending: aiTask != nil) {
            if action == .wait { return true }
            let revision = presentationRevision
            if action == .accept, acceptAICompletion(to: client) { return true }
            guard revision == presentationRevision else { return false }
            return requestAICompletion(to: client)
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
            sentenceSubmissionGeneration = nil
            guard !session.buffer.isEmpty else { session.breakContext(); return false }
            session.reset()
            update(client)
            return true
        case 36, 76: // Return / keypad Enter: preserve the original spelling.
            guard !session.buffer.isEmpty else {
                session.breakContext()
                if !event.isARepeat, !event.modifierFlags.contains(.shift) { captureSentence(from: client) }
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
        let memory = appSettings.snapshot()
        let languages = LanguageSettings.shared
        let secureInput = IsSecureEventInputEnabled()
        session.configure(languages: languages.enabledLanguages,
                          learning: memory.learning,
                          dictionary: UserDictionarySettings.shared.dictionaryForInput,
                          contextGeneration: sessionContextGeneration,
                          automaticConfirmationEnabled: languages.automaticConfirmationEnabled && !secureInput,
                          configurationGeneration: languages.configurationGeneration,
                          applicationMemory: memory,
                          punctuationCandidatesEnabled: languages.punctuationCandidatesEnabled,
                          rankingExperiment: secureInput ? RankingExperiment() : languages.productionRanking)
        if let client = eventClient ?? client() { return refreshLanguageModelContext(from: client) }
        session.setLanguageModelContext(.empty)
        return true
    }

    private func refreshLanguageModelContext(from client: any IMKTextInput) -> Bool {
        let languages = LanguageSettings.shared
        guard !session.buffer.isEmpty, languages.enabledLanguages.contains(.simplifiedChinese),
              languages.productionRanking.isActive, !IsSecureEventInputEnabled(),
              !languages.usesPassthrough(in: applicationID) else {
            session.setLanguageModelContext(.empty)
            return true
        }
        let revision = presentationRevision
        let generation = languages.configurationGeneration
        let contextGeneration = sessionContextGeneration
        let app = applicationID
        let isCurrent = {
            revision == self.presentationRevision && contextGeneration == self.sessionContextGeneration
                && generation == languages.configurationGeneration && app == self.applicationID
                && (self.client() as AnyObject?) === (client as AnyObject)
                && !IsSecureEventInputEnabled() && !languages.usesPassthrough(in: app)
        }
        let context = KenLMContextReader.read(markedText: markedTextState.text, isCurrent: isCurrent,
            selection: { client.selectedRange() }, markedRange: { client.markedRange() },
            text: { client.attributedSubstring(from: $0)?.string })
        guard isCurrent() else { return false }
        session.setLanguageModelContext(context ?? .empty)
        return true
    }

    private func stopConversionForDirectInput(in client: any IMKTextInput) {
        presentationRevision &+= 1
        invalidateAICompletion()
        sentenceSubmissionGeneration = nil
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
            sentenceSubmissionGeneration = nil
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
        explicitlyNavigated = true
        selection.setExpanded(expanded)
        updateAISelection(to: client)
    }

    private func moveCandidateSelection(_ navigation: CandidateSelection.Navigation, to eventClient: (any IMKTextInput)? = nil) {
        guard !session.buffer.isEmpty, let client = eventClient ?? client() else { return }
        guard configureSession(for: client) else { return }
        session.suspendAutomaticConfirmation()
        automaticConfirmationTask?.cancel()
        selection.navigate(navigation)
        explicitlyNavigated = true
        updateAISelection(to: client)
    }

    private func presentCandidates(to client: any IMKTextInput) {
        guard candidatePanel.ownsPresentation else { return }
        let revision = presentationRevision
        let screens = NSScreen.screens.map { CandidatePlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        // Host geometry calls can synchronously service another IMK event. Resolve on
        // a value copy so reentry cannot overlap a mutating access to controller state.
        var nextAnchor = candidateAnchor
        let marked = MarkedTextPresentation(buffer: session.buffer, cursor: session.cursor, candidates: session.candidates)
        let caret = nextAnchor.resolve(cursorUTF16Offset: marked.cursorUTF16Offset, markedRange: client.markedRange(),
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
                            isPending: session.pendingCandidateRequest != nil, refreshPendingRows: session.hasCandidatePreview,
                            prediction: aiPrediction.map { $0.candidate.text + $0.suffix },
                            predictionStatus: aiPrediction == nil ? aiRowPhase?.message : nil)
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
            invalidateAICompletion()

            candidateAnchor.reset()
            markedTextState.reset()
            sentenceSubmissionGeneration = nil
            memoryClient = nil
            applicationID = nil
            candidatePanel.claimPresentation()
        }
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        MainActor.assumeIsolated {
            presentationRevision &+= 1
            invalidateAICompletion()
            sentenceSubmissionGeneration = nil
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
        // Menu callbacks use the same IMK main-thread boundary as showPreferences.
        let state = MainActor.assumeIsolated {
            (english: LanguageSettings.shared.englishEnabled,
             chinese: LanguageSettings.shared.chineseEnabled,
             canCheckForUpdates: (NSApplication.shared.delegate as? AppDelegate)?.updater.canCheckForUpdates ?? false)
        }
        let menu = NSMenu(title: "SI")
        menu.autoenablesItems = false
        // Separate selectors avoid relying on NSMenuItem targets or represented objects
        // surviving IMK's doCommandBySelector:commandDictionary: bridge.
        let english = menu.addItem(withTitle: L10n.text("English"), action: #selector(toggleEnglish(_:)), keyEquivalent: "")
        english.state = state.english ? .on : .off
        let chinese = menu.addItem(withTitle: L10n.text("Chinese (Simplified)"), action: #selector(toggleChinese(_:)), keyEquivalent: "")
        chinese.state = state.chinese ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("SI Settings…"), action: #selector(showPreferences(_:)), keyEquivalent: "")
        // IMK dispatches menu selectors here via doCommandBySelector:commandDictionary:.
        let item = menu.addItem(withTitle: L10n.text("Check for Updates…"), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.isEnabled = state.canCheckForUpdates
        return menu
    }

    @objc nonisolated private func toggleEnglish(_ sender: Any!) {
        MainActor.assumeIsolated {
            LanguageSettings.shared.englishEnabled.toggle()
            refreshLanguageConfiguration()
        }
    }

    @objc nonisolated private func toggleChinese(_ sender: Any!) {
        MainActor.assumeIsolated {
            LanguageSettings.shared.chineseEnabled.toggle()
            refreshLanguageConfiguration()
        }
    }

    private func refreshLanguageConfiguration() {
        // Refresh only this client's active composition, retaining spelling and caret.
        // Other sessions recheck the shared configuration at their existing boundaries.
        guard candidatePanel.ownsPresentation, let client = client(),
              configureSession(for: client), !session.buffer.isEmpty else { return }
        update(client)
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
        invalidateAICompletion()
        automaticConfirmationTask?.cancel()
        let sameClient = candidateClient.map { ($0 as AnyObject) === (client as AnyObject) } ?? false
        if !sameClient {
            markedTextState.reset()
            candidateAnchor.reset()
        }
        candidateClient = client
        selection.update(session.candidates)
        explicitlyNavigated = false
        let marked = MarkedTextPresentation(buffer: session.buffer, cursor: session.cursor, candidates: session.candidates)
        let markedSelection = NSRange(location: marked.cursorUTF16Offset, length: 0)
        if markedTextState.shouldSend(marked.text, selection: markedSelection) {
            client.setMarkedText(marked.text, selectionRange: markedSelection,
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        // A nested key, commit or focus callback supersedes this host update.
        guard revision == presentationRevision, candidatePanel.ownsPresentation else { return }
        guard refreshLanguageModelContext(from: client), revision == presentationRevision else { return }
        selection.update(session.candidates)
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

    private func updateAISelection(to client: any IMKTextInput) {
        presentationRevision &+= 1
        let revision = presentationRevision
        invalidateAICompletion()
        presentCandidates(to: client)
        guard revision == presentationRevision else { return }
    }

    private func invalidateAICompletion() {
        aiTask?.cancel()
        aiTask = nil
        aiPrediction = nil
        aiRowPhase = nil
        if let aiRequestID { AICompletionActivity.shared.update(.cancelled, requestID: aiRequestID) }
        aiRequestID = nil
    }

    private func showAIPhase(_ phase: AICompletionActivity.Phase, requestID: UUID, to client: any IMKTextInput) {
        guard aiRequestID == requestID else { return }
        AICompletionActivity.shared.update(phase, requestID: requestID)
        aiRowPhase = phase
        presentCandidates(to: client)
    }

    private func aiContextIsCurrent(revision: UInt64, settingsGeneration: UInt64, languageGeneration: UInt64,
                                    app: String, pid: pid_t, client: any IMKTextInput) -> Bool {
        let settings = AICompletionSettings.shared
        let languages = LanguageSettings.shared
        let activeClient = self.client()
        return candidatePanel.ownsPresentation && candidatePanel.isVisible && revision == presentationRevision
            && (candidateClient as AnyObject?) === (client as AnyObject)
            && (activeClient as AnyObject?) === (client as AnyObject)
            && applicationID == app && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            && settings.generation == settingsGeneration && settings.enabled
            && languages.configurationGeneration == languageGeneration
            && !languages.usesPassthrough(in: app) && !IsSecureEventInputEnabled()
    }

    private func aiField(from client: any IMKTextInput, isCurrent: @MainActor () -> Bool) -> AICompletionField? {
        let marked = MarkedTextPresentation(buffer: session.buffer, cursor: session.cursor, candidates: session.candidates)
        return AICompletionField.read(markedText: marked.text, cursorUTF16Offset: marked.cursorUTF16Offset,
                                      isCurrent: isCurrent, selection: { client.selectedRange() },
                                      markedRange: { client.markedRange() }, length: { client.length() },
                                      text: { client.attributedSubstring(from: $0)?.string })
    }

    private func aiPosition(from client: any IMKTextInput,
                            isCurrent: @MainActor () -> Bool) -> AICompletionField.Position? {
        guard isCurrent() else { return nil }
        let marked = client.markedRange()
        guard isCurrent() else { return nil }
        let selection = client.selectedRange()
        guard isCurrent() else { return nil }
        return .init(marked: marked, selection: selection)
    }

    /// Plain Tab owns this request. Ordinary edits and candidate delivery never start AI work.
    private func requestAICompletion(to client: any IMKTextInput) -> Bool {
        let settings = AICompletionSettings.shared
        guard settings.enabled, !session.buffer.isEmpty, !IsSecureEventInputEnabled(),
              let app = applicationID, let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == app, !LanguageSettings.shared.usesPassthrough(in: app) else { return false }
        resolveCandidates(to: client)
        guard configureSession(for: client), !session.buffer.isEmpty else { return false }
        session.suspendAutomaticConfirmation()
        automaticConfirmationTask?.cancel()
        let activity = AICompletionActivity.shared
        let requestID = activity.begin(.readingContext)
        aiRequestID = requestID
        guard CGPreflightScreenCaptureAccess() else {
            settings.reportFailure(AICompletionScreenshot.Failure.permissionRequired.message)
            showAIPhase(.failed, requestID: requestID, to: client)
            return true
        }
        guard session.cursor == session.buffer.count else {
            showAIPhase(.moveCaretToEnd, requestID: requestID, to: client)
            return true
        }
        guard session.buffer.utf8.count <= 512,
              let candidate = (currentCandidate?.isPartial == false ? currentCandidate : nil)
                ?? session.candidates.first(where: { !$0.isPartial }), !candidate.isPunctuation,
              candidate.text.utf8.count <= 512 else {
            showAIPhase(.selectWholeCandidate, requestID: requestID, to: client)
            return true
        }
        settings.reportFailure(nil)
        let input = session.buffer
        let pid = front.processIdentifier
        let revision = presentationRevision
        let windowLevel = Int(client.windowLevel())
        guard revision == presentationRevision, aiRequestID == requestID else { return true }
        guard let window = AICompletionScreenshot.frontWindow(pid: pid, level: windowLevel) else {
            settings.reportFailure(AICompletionScreenshot.Failure.windowNotFound(windowLevel).message)
            showAIPhase(.failed, requestID: requestID, to: client)
            return true
        }
        let settingsGeneration = settings.generation
        let languageGeneration = LanguageSettings.shared.configurationGeneration
        let provider = settings.provider
        let cliPath = settings.cliPath
        let selectionID = currentCandidate?.id
        showAIPhase(.readingContext, requestID: requestID, to: client)
        guard revision == presentationRevision, aiRequestID == requestID else { return true }
        aiTask = Task { [weak self, weak client] in
            guard let self, let client else { return }
            defer {
                if self.aiRequestID == requestID { self.aiTask = nil }
                activity.finishIfPending(requestID: requestID)
            }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && self.aiContextIsCurrent(revision: revision, settingsGeneration: settingsGeneration,
                    languageGeneration: languageGeneration, app: app, pid: pid, client: client)
                    && AICompletionScreenshot.frontWindow(pid: pid, level: window.level) == window
            }
            do {
                guard isCurrent() else { return }
                let field = self.aiField(from: client, isCurrent: isCurrent)
                let position = self.aiPosition(from: client, isCurrent: isCurrent)
                guard isCurrent() else { return }
                let screenshot = try await AICompletionScreenshot.capture(window: window)
                guard isCurrent() else { return }
                let key = provider == .openAI ? await AICompletionCredentials.shared.read() : nil
                guard isCurrent(), self.aiField(from: client, isCurrent: isCurrent) == field, isCurrent(),
                      self.aiPosition(from: client, isCurrent: isCurrent) == position, isCurrent() else { return }
                let context = AICompletionContext(currentInput: input, candidate: candidate.text,
                                                  fieldBefore: field?.before, fieldAfter: field?.after)
                self.showAIPhase(.predicting, requestID: requestID, to: client)
                guard isCurrent() else { return }
                let suffix = try await provider.predict(context, cliPath: cliPath, apiKey: key, screenshot: screenshot.png)
                guard isCurrent() else { return }
                guard self.aiField(from: client, isCurrent: isCurrent) == field, isCurrent(),
                      self.aiPosition(from: client, isCurrent: isCurrent) == position, isCurrent() else {
                    if isCurrent() { self.showAIPhase(.contextChanged, requestID: requestID, to: client) }
                    return
                }
                settings.reportFailure(nil)
                guard let suffix else {
                    self.showAIPhase(.noSuggestion, requestID: requestID, to: client)
                    return
                }
                self.aiPrediction = AIPrediction(revision: revision, settingsGeneration: settingsGeneration,
                    languageGeneration: languageGeneration, application: app, pid: pid, candidate: candidate,
                    field: field, position: position, window: window, selectionID: selectionID, suffix: suffix)
                self.showAIPhase(.ready, requestID: requestID, to: client)
            } catch {
                guard isCurrent() else { return }
                settings.reportFailure((error as? AICompletionScreenshot.Failure)?.message
                    ?? (error as? AICompletionProvider.Failure)?.message ?? AICompletionProvider.Failure.request.message)
                self.showAIPhase(.failed, requestID: requestID, to: client)
            }
        }
        return true
    }

    private func acceptAICompletion(to client: any IMKTextInput) -> Bool {
        guard let prediction = aiPrediction, configureSession(for: client) else { return false }
        func isCurrent() -> Bool {
            aiContextIsCurrent(revision: prediction.revision, settingsGeneration: prediction.settingsGeneration,
                               languageGeneration: prediction.languageGeneration, app: prediction.application,
                               pid: prediction.pid, client: client)
        }
        guard CGPreflightScreenCaptureAccess(), session.pendingCandidateRequest == nil,
              currentCandidate?.id == prediction.selectionID,
              session.candidates.contains(where: { $0 == prediction.candidate }),
              isCurrent(), aiField(from: client, isCurrent: isCurrent) == prediction.field, isCurrent(),
              aiPosition(from: client, isCurrent: isCurrent) == prediction.position, isCurrent(),
              AICompletionScreenshot.frontWindow(pid: prediction.pid, level: prediction.window.level) == prediction.window, isCurrent() else {
            // Never cancel work or refresh a panel created by a reentrant key.
            if aiPrediction?.revision == prediction.revision, presentationRevision == prediction.revision,
               candidatePanel.ownsPresentation, (candidateClient as AnyObject?) === (client as AnyObject) {
                invalidateAICompletion()
                presentCandidates(to: client)
            }
            return false
        }
        let commit = session.commitResult(prediction.candidate, reason: .aiCompletion)
        apply(commit, suffix: prediction.suffix, to: client)
        return true
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
        invalidateAICompletion()
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
        let history = InputHistorySettings.shared
        let historyGeneration = history.generation
        let recordsHistory = history.canRecord
        let sentences = InputHistorySettings.sentences
        let sentenceGeneration = sentences.generation
        let tracksSentence = sentences.canCaptureSentence(in: app)
        guard insert(commit.text + suffix, into: client) else { return }
        guard app == applicationID else { return }
        guard !LanguageSettings.shared.usesPassthrough(in: app) else {
            configureSession(for: client)
            return
        }
        if recordsHistory { history.record(commit, suffix: suffix, expectedGeneration: historyGeneration) }
        if tracksSentence, sentenceGeneration == sentences.generation, sentences.canCaptureSentence(in: app),
           (memoryClient as AnyObject?) === (client as AnyObject), !commit.text.isEmpty {
            sentenceSubmissionGeneration = sentenceGeneration
            sentences.sentenceCaptureStatus = .waitingForReturn
        }
        if generation == ApplicationMemorySettings.shared.generation {
            ApplicationMemorySettings.shared.recordVocabulary(commit)
        }
        configureSession(for: client)
        if !session.buffer.isEmpty { update(client) }
    }

    private func captureSentence(from client: any IMKTextInput) {
        guard let generation = sentenceSubmissionGeneration else { return }
        sentenceSubmissionGeneration = nil
        let history = InputHistorySettings.sentences
        let app = applicationID
        let revision = presentationRevision
        func isCurrent() -> Bool {
            generation == history.generation && revision == presentationRevision
                && (memoryClient as AnyObject?) === (client as AnyObject)
                && app == applicationID && !LanguageSettings.shared.usesPassthrough(in: app)
                && history.canCaptureSentence(in: app) && session.buffer.isEmpty
        }

        guard let text = SentenceSnapshotReader.read(isCurrent: isCurrent, selection: { client.selectedRange() },
                                                     markedRange: { client.markedRange() },
                                                     textInRange: { client.attributedSubstring(from: $0)?.string },
                                                     onFailure: {
                                                         if generation == history.generation, history.enabled {
                                                             history.sentenceCaptureStatus = .skipped($0)
                                                         }
                                                     }) else { return }
        guard isCurrent() else { return }
        history.recordSentence(text, in: app, expectedGeneration: generation)
        history.sentenceCaptureStatus = .captured
    }
}
