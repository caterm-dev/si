import AppKit
import InputMethodKit
import Carbon

// InputMethodKit resolves this stable Objective-C name from Info.plist.
@MainActor
@objc(SIInputController)
// The legacy superclass is not Sendable. All mutable state remains main-actor isolated.
final class SIInputController: IMKInputController, @unchecked Sendable {
    private var session = InputSession(engine: CandidateEngine(usesCoverageAdjustedOrder: false))
    private weak var candidateClient: (any IMKTextInput)?
    private var selection = CandidateSelection()
    private var markedTextState = MarkedTextState()
    private var presentationRevision: UInt64 = 0
    private var candidatePlacementRevision: UInt64 = 0
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
    private weak var memoryClient: (any IMKTextInput)?
    private var applicationID: String?
    private var memoryGeneration: UInt64?
    private var memoryLanguageGeneration: UInt64?
    private var sessionContextGeneration: UInt64 = 0
    private var keyEventGeneration: UInt64 = 0
    private struct ReturnFieldCapture {
        let client: any IMKTextInput
        let application: String
        let keyGeneration: UInt64
        let learningGeneration: UInt64
        let languageGeneration: UInt64
        let text: String
    }
    private var returnFieldCapture: ReturnFieldCapture?

    private lazy var candidatePanel: CandidatePanel = {
        let panel = CandidatePanel()
        panel.onLosePresentation = { [weak self] in
            guard let self else { return }
            self.presentationRevision &+= 1
            self.markedTextState.resetCandidateStart()
            self.session.setPrecedingText(nil)
            self.invalidateAICompletion()
        }
        panel.list.onSelect = { [weak self] id in
            guard let self, self.candidatePanel.ownsPresentation, let client = self.client(),
                  let candidate = self.session.candidates.first(where: { $0.id == id }) else { return }
            guard self.configureSession(for: client) else {
                self.update(client)
                return
            }
            self.commitCandidate(candidate, to: client)
        }
        panel.list.onSelectPrediction = { [weak self] in
            guard let self, let client = self.client() else { return }
            _ = self.acceptAICompletion(to: client)
        }
        panel.list.onToggleExpansion = { [weak self] in
            guard let self, self.candidatePanel.ownsPresentation,
                  let client = self.client() else { return }
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
        AppLearningContext.shared.update(client)
        keyEventGeneration &+= 1
        let keyGeneration = keyEventGeneration
        if let capture = returnFieldCapture {
            finishReturnFieldLearning(readBack: (capture.client as AnyObject) === (client as AnyObject))
            guard keyGeneration == keyEventGeneration else { return false }
        }
        // Check before the passthrough guard so the shortcut can restore conversion too.
        if LanguageSettings.shared.directInputShortcut.matches(keyCode: event.keyCode, modifiers: event.modifierFlags),
           !IsSecureEventInputEnabled(), let identifier = client.bundleIdentifier(), !identifier.isEmpty {
            if !event.isARepeat {
                prepareApplicationMemory(for: client)
                LanguageSettings.shared.togglePassthrough(for: identifier)
                _ = configureSession(for: client)
                session.breakContext()
            }
            return true
        }
        candidatePanel.claimPresentation()
        let previousCandidates = session.candidates
        guard configureSession(for: client) else { return false }
        if previousCandidates != session.candidates { update(client) }

        let isLearningReturn = ReturnFieldLearning.matches(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                                           isRepeat: event.isARepeat)
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            commitLiteral(to: client)
            if isLearningReturn { beginReturnFieldLearning(from: client, keyGeneration: keyGeneration) }
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
                if isLearningReturn { beginReturnFieldLearning(from: client, keyGeneration: keyGeneration) }
                session.breakContext()
                return false
            }
            commitLiteral(to: client)
            return true
        case 49: // Space
            guard !session.buffer.isEmpty else { return false }
            acceptCandidate(currentCandidate, to: client)
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
            return append(text, to: client)
        }
        let punctuation = LanguageSettings.shared.punctuationBehavior
        if session.buffer.isEmpty, LanguageSettings.shared.punctuationCandidatesEnabled,
           !LanguageSettings.shared.enabledLanguages.isEmpty,
           PunctuationCandidates.recognizes(text) {
            return append(text, to: client)
        }
        if !session.buffer.isEmpty, CompositionBoundary.keepsInComposition(text: text, behavior: punctuation) {
            session.append(text)
            update(client)
            return true
        }
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

    private func append(_ text: String, to client: any IMKTextInput) -> Bool {
        if session.buffer.isEmpty, !refreshPrecedingText(for: client) { return false }
        session.append(text)
        update(client)
        return true
    }

    private func beginReturnFieldLearning(from client: any IMKTextInput, keyGeneration: UInt64) {
        let learning = SentenceLearningSettings.shared
        let languages = LanguageSettings.shared
        guard learning.canRecord, let app = applicationID, !languages.usesPassthrough(in: app) else { return }
        let learningGeneration = learning.generation
        let languageGeneration = languages.configurationGeneration
        let revision = presentationRevision
        guard let text = readReturnField(from: client, isCurrent: {
            self.ownsReturnField(client, application: app) && self.presentationRevision == revision
                && self.keyEventGeneration == keyGeneration && learning.canRecord
                && learning.generation == learningGeneration && languages.configurationGeneration == languageGeneration
        }), keyGeneration == keyEventGeneration, !text.isEmpty else { return }
        returnFieldCapture = ReturnFieldCapture(client: client, application: app, keyGeneration: keyGeneration,
                                                learningGeneration: learningGeneration,
                                                languageGeneration: languageGeneration, text: text)
        // IMK has no host-completion callback for a passed-through key.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) {
            guard self.returnFieldCapture?.keyGeneration == keyGeneration else { return }
            self.finishReturnFieldLearning()
        }
    }

    private func finishReturnFieldLearning(readBack: Bool = true) {
        guard let capture = returnFieldCapture else { return }
        returnFieldCapture = nil
        let learning = SentenceLearningSettings.shared
        let languages = LanguageSettings.shared
        func canRecord() -> Bool {
            learning.canRecord && learning.generation == capture.learningGeneration
                && languages.configurationGeneration == capture.languageGeneration
                && !languages.usesPassthrough(in: capture.application)
        }
        guard canRecord() else { return }
        let keyGeneration = keyEventGeneration
        let after = readBack ? readReturnField(from: capture.client, isCurrent: {
            let activeClient = self.client()
            return (activeClient as AnyObject?) === (capture.client as AnyObject)
                && self.ownsReturnField(capture.client, application: capture.application)
                && self.keyEventGeneration == keyGeneration && canRecord()
        }) : nil
        guard canRecord(), ReturnFieldLearning.shouldIngest(before: capture.text, after: after) else { return }
        learning.recordReturnField(capture.text, expectedGeneration: capture.learningGeneration)
    }

    private func ownsReturnField(_ client: any IMKTextInput, application: String) -> Bool {
        applicationID == application && candidatePanel.ownsPresentation
            && (memoryClient as AnyObject?) === (client as AnyObject)
    }

    private func readReturnField(from client: any IMKTextInput, isCurrent: () -> Bool) -> String? {
        ReturnFieldLearning.read(isCurrent: isCurrent, selection: { client.selectedRange() },
                                 markedRange: { client.markedRange() },
                                 text: { client.attributedSubstring(from: $0)?.string },
                                 textWithActualRange: { range in
            var actual = NSRange(location: NSNotFound, length: 0)
            guard let text = client.string(from: range, actualRange: &actual) else { return nil }
            return (text, actual)
        })
    }

    /// The host owns the field. A nested input or focus callback invalidates this capture.
    private func refreshPrecedingText(for client: any IMKTextInput) -> Bool {
        let revision = presentationRevision
        let keyGeneration = keyEventGeneration
        let languages = LanguageSettings.shared
        let languageGeneration = languages.configurationGeneration
        let app = applicationID
        func unchanged() -> Bool {
            revision == presentationRevision && keyGeneration == keyEventGeneration
                && candidatePanel.ownsPresentation && (memoryClient as AnyObject?) === (client as AnyObject)
        }
        func isCurrent() -> Bool {
            unchanged() && (self.client() as AnyObject?) === (client as AnyObject)
                && app != nil && app == applicationID && languageGeneration == languages.configurationGeneration
                && !languages.usesPassthrough(in: app) && !languages.enabledLanguages.isEmpty
                && !IsSecureEventInputEnabled()
        }
        let prefix = PrecedingTextReader.read(isCurrent: isCurrent, selection: { client.selectedRange() },
                                             markedRange: { client.markedRange() },
                                             text: { client.attributedSubstring(from: $0)?.string })
        guard unchanged() else { return false }
        session.setPrecedingText(isCurrent() ? prefix : nil)
        return true
    }

    private func commitCandidate(_ candidate: InputCandidate?, to client: any IMKTextInput) {
        guard let candidate else { return }
        // Mouse selection can arrive after consent, deletion or secure-input changes without a key event.
        guard configureSession(for: client) else { return }
        guard let current = session.candidates.first(where: {
            $0.id == candidate.id && $0.isPinyinCorrection == candidate.isPinyinCorrection
                && $0.text.utf8.elementsEqual(candidate.text.utf8)
        }) else { update(client); return }
        acceptCandidate(current, to: client)
    }

    private func acceptCandidate(_ candidate: InputCandidate?, to client: any IMKTextInput) {
        let revision = presentationRevision
        let keyGeneration = keyEventGeneration
        let contextGeneration = sessionContextGeneration
        let languages = LanguageSettings.shared
        let languageGeneration = languages.configurationGeneration
        let secure = IsSecureEventInputEnabled()
        func unchanged() -> Bool {
            revision == presentationRevision && keyGeneration == keyEventGeneration
                && contextGeneration == sessionContextGeneration && candidatePanel.ownsPresentation
                && (memoryClient as AnyObject?) === (client as AnyObject)
                && languageGeneration == languages.configurationGeneration
                && !languages.usesPassthrough(in: applicationID) && secure == IsSecureEventInputEnabled()
        }
        func isCurrent() -> Bool {
            unchanged() && (self.client() as AnyObject?) === (client as AnyObject) && unchanged()
        }
        let presentation = MarkedTextPresentation(buffer: session.buffer, cursor: session.cursor, candidates: session.candidates)
        let boundary = secure ? nil : CandidateBoundaryReader.read(
            markedText: markedTextState.text ?? presentation.text,
            cursorUTF16Offset: markedTextState.caretUTF16Offset ?? presentation.cursorUTF16Offset,
            isCurrent: isCurrent, selection: { client.selectedRange() }, markedRange: { client.markedRange() },
            textWithActualRange: { range in
                var actual = NSRange(location: NSNotFound, length: 0)
                guard let text = client.string(from: range, actualRange: &actual) else { return nil }
                return (text, actual)
            },
            text: { client.attributedSubstring(from: $0)?.string })
        guard isCurrent() else { return }
        let commit = session.commitResult(candidate, reason: selection.confirmationReason(for: candidate))
        let spacing = CandidateSpacing(commit: commit, before: boundary)
        apply(commit, prefix: spacing.prefix, to: client)
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
        let memory = appSettings.snapshot(sentenceModel: SentenceLearningSettings.shared.modelForInput)
        let languages = LanguageSettings.shared
        let secureInput = IsSecureEventInputEnabled()
        if secureInput { session.setPrecedingText(nil) }
        session.configure(languages: languages.enabledLanguages,
                          learning: memory.learning,
                          dictionary: UserDictionary(),
                          contextGeneration: sessionContextGeneration,
                          configurationGeneration: languages.configurationGeneration,
                          applicationMemory: memory,
                          compositionLearningEnabled: !secureInput,
                          punctuationCandidatesEnabled: languages.punctuationCandidatesEnabled,
                          pinyinCorrectionMode: languages.pinyinCorrectionEnabled && !secureInput ? .conservative : .off,
                          rerankingEnabled: languages.localModelRankingEnabled && !secureInput,
                          useLargeModel: languages.useLargeModel)
        return true
    }

    private func stopConversionForDirectInput(in client: any IMKTextInput) {
        presentationRevision &+= 1
        invalidateAICompletion()
        let spelling = session.buffer
        session.reset()
        candidateClient = nil
        selection.update([])
        explicitlyNavigated = false
        markedTextState.reset()
        // Preserve only the pending spelling, once, without learning or a space.
        if !spelling.isEmpty { insert(spelling, into: client) }
        else { candidatePanel.orderOut(nil) }
    }

    private func prepareApplicationMemory(for client: any IMKTextInput) {
        let sameClient = memoryClient.map { ($0 as AnyObject) === (client as AnyObject) } ?? false
        if !sameClient {
            session.setPrecedingText(nil)
            let identifier = client.bundleIdentifier()
            memoryClient = client
            applicationID = identifier.flatMap { $0.isEmpty ? nil : $0 }
            memoryGeneration = nil
            sessionContextGeneration &+= 1
        }
        let settings = ApplicationMemorySettings.shared
        let languageGeneration = LanguageSettings.shared.configurationGeneration
        if let memoryGeneration, memoryGeneration != settings.generation
            || memoryLanguageGeneration != languageGeneration {
            sessionContextGeneration &+= 1
        }
        memoryGeneration = settings.generation
        memoryLanguageGeneration = languageGeneration
    }

    private var currentCandidate: InputCandidate? {
        selection.selected
    }

    private func setCandidateListExpanded(_ expanded: Bool, to client: any IMKTextInput) {
        guard !session.buffer.isEmpty, candidatePanel.ownsPresentation else { return }
        explicitlyNavigated = true
        selection.setExpanded(expanded)
        updateAISelection(to: client)
    }

    private func moveCandidateSelection(_ navigation: CandidateSelection.Navigation, to client: any IMKTextInput) {
        guard !session.buffer.isEmpty, configureSession(for: client) else { return }
        selection.navigate(navigation)
        explicitlyNavigated = true
        updateAISelection(to: client)
    }

    private func refreshCandidatePanel(to client: any IMKTextInput) {
        guard candidatePanel.ownsPresentation, markedTextState.text != nil else { return }
        let revision = presentationRevision
        candidatePlacementRevision &+= 1
        let placementRevision = candidatePlacementRevision
        guard !selection.candidates.isEmpty else {
            candidatePanel.orderOut(nil)
            return
        }
        if let anchor = markedTextState.candidateStart {
            candidatePanel.fit(selection: &selection, at: anchor,
                               prediction: aiPrediction.map { $0.candidate.text + $0.suffix },
                               predictionStatus: aiPrediction == nil ? aiRowPhase?.message : nil)
        } else {
            candidatePanel.render(selection: selection,
                                  prediction: aiPrediction.map { $0.candidate.text + $0.suffix },
                                  predictionStatus: aiPrediction == nil ? aiRowPhase?.message : nil)
        }
        // Render at the captured start after the current row layout is ready.
        DispatchQueue.main.async { [weak self, weak client] in
            guard let self, let client else { return }
            self.positionCandidatePanel(for: client, revision: revision, placementRevision: placementRevision)
        }
    }

    private func positionCandidatePanel(for client: any IMKTextInput, revision: UInt64, placementRevision: UInt64) {
        let clientObject = client as AnyObject
        func isCurrent() -> Bool {
            revision == presentationRevision && placementRevision == candidatePlacementRevision
                && candidatePanel.ownsPresentation && markedTextState.text != nil
                && (candidateClient as AnyObject?) === clientObject
                && !LanguageSettings.shared.usesPassthrough(in: applicationID)
        }
        // A host call can synchronously service another IMK event. Recheck after each
        // call before using its result or making another request against the old client.
        guard isCurrent(), let activeClient = self.client(), (activeClient as AnyObject) === clientObject,
              isCurrent() else { return }
        // TEMP-GEOMETRY-LOG
        #if DEBUG
        var samples: [(index: Int, rect: CGRect)] = []
        var selectedIndex: Int?
        #endif
        // Ask after marked-text layout. Same-line caret motion never changes the
        // anchor; a visual-line transition resolves that line's first character.
        if markedTextState.candidateStart != nil,
           let text = markedTextState.text, let caret = markedTextState.caretUTF16Offset {
            let screens = NSScreen.screens.map { CandidatePlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
            let marked = client.markedRange()
            guard isCurrent() else { return }
            var rangesAreCurrent = true
            let line = CandidateAnchor.activeLine(inlineText: text, caretUTF16Offset: caret,
                retainedStart: markedTextState.candidateLineStartUTF16Offset, screens: screens) { index in
                CandidateGeometryReader.read(inlineOffset: index,
                    documentBounds: marked.length == text.utf16.count ? marked : nil, screens: screens,
                    isCurrent: { isCurrent() && rangesAreCurrent }, documentRectangle: { range in
                        var actual = NSRange(location: NSNotFound, length: 0)
                        let rect = client.firstRect(forCharacterRange: range, actualRange: &actual)
                        guard isCurrent() else { return nil }
                        let currentMarked = client.markedRange()
                        rangesAreCurrent = currentMarked == marked
                        guard isCurrent(), rangesAreCurrent else { return nil }
                        // TEMP-GEOMETRY-LOG
                        #if DEBUG
                        if !IsSecureEventInputEnabled() { samples.append((range.location, rect)) }
                        #endif
                        return (rect, actual)
                    }, inlineRectangle: { index in
                        var rect = NSRect.zero
                        _ = client.attributes(forCharacterIndex: index, lineHeightRectangle: &rect)
                        // TEMP-GEOMETRY-LOG
                        #if DEBUG
                        if !IsSecureEventInputEnabled() { samples.append((index, rect)) }
                        #endif
                        return rect
                    })
            }
            guard isCurrent(), rangesAreCurrent else { return }
            if let line {
                markedTextState.updateCandidateLine(offset: line.offset, anchor: line.anchor)
                // TEMP-GEOMETRY-LOG
                #if DEBUG
                selectedIndex = line.offset
                #endif
            }
        }
        guard let anchor = markedTextState.candidateStart else {
            candidatePanel.orderOut(nil)
            return
        }
        let clientLevel = Int(client.windowLevel())
        guard isCurrent() else { return }
        candidatePanel.fit(selection: &selection, at: anchor,
                           prediction: aiPrediction.map { $0.candidate.text + $0.suffix },
                           predictionStatus: aiPrediction == nil ? aiRowPhase?.message : nil)
        candidatePanel.show(at: anchor, clientLevel: clientLevel)
        // TEMP-GEOMETRY-LOG
        #if DEBUG
        if SettingsDefaults.shared.bool(forKey: CandidateGeometryLog.preferenceKey), !IsSecureEventInputEnabled() {
            let marked = client.markedRange()
            guard isCurrent() else { return }
            let selected = client.selectedRange()
            guard isCurrent(), !IsSecureEventInputEnabled() else { return }
            CandidateGeometryLog.shared.append(.init(
                time: Date(), bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
                markedRange: marked, selectedRange: selected, samples: samples, selectedIndex: selectedIndex,
                screen: anchor.screen, windowFrame: candidatePanel.isVisible ? candidatePanel.frame : nil
            ))
        }
        #endif
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
            if let client = client() { AppLearningContext.shared.update(client) }
            finishReturnFieldLearning(readBack: false)
            presentationRevision &+= 1
            invalidateAICompletion()

            markedTextState.reset()
            session.setPrecedingText(nil)
            memoryClient = nil
            applicationID = nil
            candidatePanel.claimPresentation()
        }
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        MainActor.assumeIsolated {
            AppLearningContext.shared.clear(client())
            finishReturnFieldLearning(readBack: false)
            presentationRevision &+= 1
            invalidateAICompletion()
            session.breakContext()
            candidateClient = nil
            markedTextState.reset()
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
        let sameClient = candidateClient.map { ($0 as AnyObject) === (client as AnyObject) } ?? false
        if !sameClient {
            markedTextState.reset()
        }
        candidateClient = client

        selection.update(session.candidates)
        explicitlyNavigated = false
        let marked = MarkedTextPresentation(buffer: session.buffer, cursor: session.cursor, candidates: session.candidates)
        let markedSelection = NSRange(location: marked.cursorUTF16Offset, length: 0)
        if !marked.text.isEmpty, !markedTextState.didCaptureCandidateStart {
            let screens = NSScreen.screens.map { CandidatePlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
            var rangesAreCurrent = true
            func isCurrent() -> Bool {
                revision == presentationRevision && candidatePanel.ownsPresentation && rangesAreCurrent
                    && (candidateClient as AnyObject?) === (client as AnyObject)
            }
            let insertion = client.selectedRange()
            guard isCurrent() else { return }
            // Before marking, document selection and inline zero both refer to
            // the insertion point. Prefer a verified document rectangle when available.
            guard let rect = CandidateGeometryReader.read(inlineOffset: 0, documentBounds: insertion, screens: screens,
                isCurrent: isCurrent, documentRectangle: { range in
                    var actual = NSRange(location: NSNotFound, length: 0)
                    let rect = client.firstRect(forCharacterRange: range, actualRange: &actual)
                    guard isCurrent() else { return nil }
                    let currentInsertion = client.selectedRange()
                    rangesAreCurrent = currentInsertion == insertion
                    guard isCurrent() else { return nil }
                    return (rect, actual)
                }, inlineRectangle: { index in
                    var rect = NSRect.zero
                    _ = client.attributes(forCharacterIndex: index, lineHeightRectangle: &rect)
                    return rect
                }) else { return }
            markedTextState.captureCandidateStart(rect, screens: screens)
        }
        if markedTextState.shouldSend(marked.text, selection: markedSelection) {
            // Use the system's thin, unselected underline, like native Pinyin.
            // This is a presentation style; the spelling remains uncommitted.
            let range = NSRange(location: 0, length: marked.text.utf16.count)
            let attributes = mark(forStyle: kTSMHiliteConvertedText, at: range) as? [NSAttributedString.Key: Any]
            let text = NSAttributedString(string: marked.text, attributes: attributes)
            client.setMarkedText(text, selectionRange: markedSelection,
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        // A nested key, commit or focus callback supersedes this host update.
        guard revision == presentationRevision, candidatePanel.ownsPresentation else { return }
        guard revision == presentationRevision else { return }
        selection.update(session.candidates)
        if session.buffer.isEmpty {
            markedTextState.reset()
            candidatePanel.orderOut(nil)
        } else {
            refreshCandidatePanel(to: client)
            guard revision == presentationRevision, candidatePanel.ownsPresentation else { return }
        }
    }

    private func updateAISelection(to client: any IMKTextInput) {
        presentationRevision &+= 1
        invalidateAICompletion()
        refreshCandidatePanel(to: client)
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
        refreshCandidatePanel(to: client)
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
        guard configureSession(for: client), !session.buffer.isEmpty else { return false }
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
              let candidate = (currentCandidate.flatMap { !$0.isPartial && !$0.requiresExplicitSelection ? $0 : nil })
                ?? session.candidates.first(where: { !$0.isPartial && !$0.requiresExplicitSelection }), !candidate.isPunctuation,
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
        guard CGPreflightScreenCaptureAccess(),
              currentCandidate?.id == prediction.selectionID,
              session.candidates.contains(where: { $0 == prediction.candidate }),
              isCurrent(), aiField(from: client, isCurrent: isCurrent) == prediction.field, isCurrent(),
              aiPosition(from: client, isCurrent: isCurrent) == prediction.position, isCurrent(),
              AICompletionScreenshot.frontWindow(pid: prediction.pid, level: prediction.window.level) == prediction.window, isCurrent() else {
            // Never cancel work or refresh a panel created by a reentrant key.
            if aiPrediction?.revision == prediction.revision, presentationRevision == prediction.revision,
               candidatePanel.ownsPresentation, (candidateClient as AnyObject?) === (client as AnyObject) {
                invalidateAICompletion()
                refreshCandidatePanel(to: client)
            }
            return false
        }
        let commit = session.commitResult(prediction.candidate, reason: .aiCompletion)
        apply(commit, suffix: prediction.suffix, to: client)
        return true
    }

    private func commitLiteral(to client: any IMKTextInput) {
        defer { session.breakContext() }
        guard !session.buffer.isEmpty else { return }
        apply(session.commitResult(reason: .literal), to: client)
    }

    @discardableResult
    private func insert(_ text: String, into client: any IMKTextInput, continuingComposition: Bool = false) -> Bool {
        presentationRevision &+= 1
        let revision = presentationRevision
        invalidateAICompletion()
        let keepsStart = continuingComposition && (candidateClient as AnyObject?) === (client as AnyObject)
        if !keepsStart { candidateClient = nil }
        // Re-mark the remainder without moving this composition's candidate anchor.
        markedTextState.reset(preservingCandidateStart: keepsStart)
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        guard revision == presentationRevision else { return false }
        selection.update([])
        explicitlyNavigated = false
        candidatePanel.orderOut(nil)
        return true
    }

    private func apply(_ commit: InputCommit, prefix: String = "", suffix: String = "", to client: any IMKTextInput) {
        let app = applicationID
        let memory = ApplicationMemorySettings.shared
        let generation = memory.generation
        let contextGeneration = sessionContextGeneration
        let languageGeneration = LanguageSettings.shared.configurationGeneration
        let recordsVocabulary = memory.usesVocabulary && !IsSecureEventInputEnabled()
        var acceptedLearning = false
        defer { if !acceptedLearning { session.discardCompositionLearning() } }
        let history = InputHistorySettings.shared
        let historyGeneration = history.generation
        let recordsHistory = history.canRecord
        guard insert(prefix + commit.text + suffix, into: client,
                     continuingComposition: !commit.remainingInput.isEmpty) else { return }
        guard app == applicationID else { return }
        guard !LanguageSettings.shared.usesPassthrough(in: app) else {
            configureSession(for: client)
            return
        }
        if recordsHistory { history.record(commit, prefix: prefix, suffix: suffix, expectedGeneration: historyGeneration) }
        if recordsVocabulary,
           (memoryClient as AnyObject?) === (client as AnyObject),
           (self.client() as AnyObject?) === (client as AnyObject), contextGeneration == sessionContextGeneration,
           languageGeneration == LanguageSettings.shared.configurationGeneration, !IsSecureEventInputEnabled(),
           generation == memory.generation, memory.usesVocabulary {
            let combined = session.recordSuccessfulCommit(commit)
            memory.recordVocabulary(commit)
            if let combined { memory.recordVocabulary(combined) }
            acceptedLearning = true
        }
        if configureSession(for: client), !session.buffer.isEmpty, refreshPrecedingText(for: client) {
            update(client)
        }
    }

}
