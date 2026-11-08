import AppKit
import Darwin
import Testing
import SICore
@testable import SIPresentation

struct AICompletionTests {
    private static let testPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6VQAAAAASUVORK5CYII=")!

    @MainActor
    @Test func snapshotsExcludeMarkedTextAndRetainUTF16Boundaries() throws {
        let marked = "ni hao"
        let text = "👋你" + marked + "后面"
        let source = text as NSString
        let range = NSRange(location: 3, length: 6)
        let caret = NSRange(location: 9, length: 0)

        let captured = AICompletionField.read(markedText: marked, cursorUTF16Offset: 6, isCurrent: { true },
                                              selection: { caret }, markedRange: { range },
                                              length: { source.length }, text: source.substring(with:))
        let snapshot = try #require(captured)
        #expect(snapshot.before == "👋你")
        #expect(snapshot.after == "后面")

        var isCurrent = true
        #expect(AICompletionField.read(markedText: marked, cursorUTF16Offset: 6, isCurrent: { isCurrent },
                                       selection: { caret }, markedRange: { range }, length: { source.length },
                                       text: { isCurrent = false; return source.substring(with: $0) }) == nil)
        #expect(AICompletionField.read(markedText: "nihao ", cursorUTF16Offset: 6, isCurrent: { true },
                                       selection: { caret }, markedRange: { range }, length: { source.length },
                                       text: source.substring(with:)) == nil)
    }

    @MainActor
    @Test func readsSurroundingTextFromNativeTextViewDuringMarkedComposition() throws {
        let host = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        host.string = "先前文字👋。"
        let insertion = ("先前文字👋" as NSString).length
        host.setSelectedRange(NSRange(location: insertion, length: 0))
        let spelling = "ni hao"
        let spellingLength = spelling.utf16.count
        host.setMarkedText(spelling, selectedRange: NSRange(location: spellingLength, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))

        let field = AICompletionField.read(
            markedText: spelling, cursorUTF16Offset: spellingLength, isCurrent: { true },
            selection: host.selectedRange, markedRange: host.markedRange, length: { host.string.utf16.count },
            text: { range in
                var actual = NSRange(location: NSNotFound, length: 0)
                let string = host.attributedSubstring(forProposedRange: range, actualRange: &actual)?.string
                return actual == range ? string : nil
            }
        )

        let snapshot = try #require(field)
        #expect(snapshot.markedRange == NSRange(location: insertion, length: spellingLength))
        #expect(snapshot.before == "先前文字👋")
        #expect(snapshot.after == "。")
    }

    @Test func fieldFreshnessUsesExactBytes() {
        let marked = NSRange(location: 0, length: 1)
        let caret = NSRange(location: 1, length: 0)
        let composed = AICompletionField(before: "", after: "\u{00E9}", markedRange: marked, selection: caret)
        let decomposed = AICompletionField(before: "", after: "e\u{0301}", markedRange: marked, selection: caret)
        #expect(composed != decomposed)
    }

    @Test func backendOutputPreservesLeadingSpaceAndRejectsHostControls() throws {
        #expect(try AICompletionProvider.decodeSuffix(#"{"suffix":" tomorrow"}"#) == " tomorrow")
        #expect(try AICompletionProvider.decodeSuffix(#"{"suffix":""}"#) == nil)
        #expect(throws: AICompletionProvider.Failure.self) {
            try AICompletionProvider.decodeSuffix(#"{"suffix":"word\nnext"}"#)
        }
        #expect(throws: AICompletionProvider.Failure.self) {
            try AICompletionProvider.decodeSuffix(#"{"suffix":"word\u202Enext"}"#)
        }
        #expect(throws: AICompletionProvider.Failure.self) {
            try AICompletionProvider.decodeSuffix("A plain answer")
        }
    }

    @Test func openAIUsesBoundedNonpersistentRequestsAndReadsOnlyTheOutputMessage() throws {
        let request = try AICompletionProvider.openAIRequest(input: "synthetic context", key: "test-key", screenshot: Self.testPNG)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try #require(body["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "synthetic context")
        #expect(content.last?["image_url"] as? String == "data:image/png;base64," + Self.testPNG.base64EncodedString())
        #expect(body["store"] as? Bool == false)
        #expect(body["tools"] == nil)
        let response = #"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"{\"suffix\":\" tomorrow\"}"}]}]}"#
        let output = try AICompletionProvider.decodeOpenAI(Data(response.utf8))
        #expect(try AICompletionProvider.decodeSuffix(output) == " tomorrow")
    }

    @Test(arguments: [AICompletionProvider.codex, .claude])
    func cliReadsPromptFromStdinAndReturnsOnlyTheFinalSuggestion(provider: AICompletionProvider) async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let executable = temporaryDirectory.appendingPathComponent("prediction-fixture")
        let response = switch provider {
        case .codex: """
            {"type":"item.completed","item":{"type":"reasoning","text":"unrelated"}}
            {"type":"item.completed","item":{"type":"agent_message","text":"{\\"suffix\\":\\" tomorrow\\"}"}}
            {"type":"turn.completed"}
            """
        case .claude: #"""
            {"is_error":false,"result":"{\"suffix\":\" tomorrow\"}"}
            """#
        case .openAI: ""
        }
        let script = """
        #!/bin/sh
        payload=$(/bin/cat)
        previous=""
        for argument in "$@"; do
            if [ "$previous" = "--image" ]; then
                /bin/cp "$argument" "$0.image.png"
                printf '%s' "$argument" > "$0.image-path"
            fi
            previous="$argument"
        done
        for expected in test-input test-before test-after; do
            case "$payload" in
                *"$expected"*) ;;
                *) exit 2 ;;
            esac
        done
        /bin/cat <<'RESPONSE'
        \(response)
        RESPONSE
        """
        try script.write(to: executable, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let context = AICompletionContext(currentInput: "test-input", candidate: "See you", fieldBefore: "test-before",
                                          fieldAfter: "test-after")
        let suffix = try await provider.predict(context, cliPath: executable.path, apiKey: nil, screenshot: Self.testPNG)
        #expect(suffix == " tomorrow")
        if provider == .codex {
            #expect(try Data(contentsOf: executable.appendingPathExtension("image.png")) == Self.testPNG)
            let path = try String(contentsOf: executable.appendingPathExtension("image-path"), encoding: .utf8)
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    @Test func openAIRunsTheHTTPAdapterAndRejectsOversizedReplies() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AICompletionTestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let context = AICompletionContext(currentInput: "seeyou", candidate: "See you", fieldBefore: "Hi.",
                                          fieldAfter: "")
        let suffix = try await AICompletionProvider.openAI.predict(context, cliPath: nil, apiKey: "test-ok", screenshot: Self.testPNG, session: session)
        #expect(suffix == " tomorrow")

        await #expect(throws: AICompletionProvider.Failure.self) {
            try await AICompletionProvider.openAI.predict(context, cliPath: nil, apiKey: "test-oversized", screenshot: Self.testPNG, session: session)
        }
        await #expect(throws: AICompletionProvider.Failure.self) {
            try await AICompletionProvider.openAI.predict(context, cliPath: nil, apiKey: "test-denied", screenshot: Self.testPNG, session: session)
        }
    }

    @Test func cancellingPredictionStopsTheRunningCLI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("prediction-fixture")
        try """
        #!/bin/sh
        /bin/cat >/dev/null
        printf '%d' "$$" > "$0.pid"
        exec /bin/sleep 30

        """.write(to: executable, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let pidFile = executable.appendingPathExtension("pid")
        let context = AICompletionContext(currentInput: "hi", candidate: "Hi", fieldBefore: nil,
                                          fieldAfter: nil)
        let task = Task {
            try await AICompletionProvider.codex.predict(context, cliPath: executable.path, apiKey: nil, screenshot: Self.testPNG)
        }
        defer { task.cancel() }

        let startupDeadline = ContinuousClock.now + .seconds(4)
        var pid: pid_t?
        while pid == nil, ContinuousClock.now < startupDeadline {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let observed = pid_t(text), observed > 0 {
                pid = observed
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let runningPID = try #require(pid)
        #expect(kill(runningPID, 0) == 0)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        let shutdownDeadline = ContinuousClock.now + .seconds(3)
        while kill(runningPID, 0) == 0, ContinuousClock.now < shutdownDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(runningPID, 0) != 0 && errno == ESRCH)
    }

    @MainActor
    @Test func pendingAndEmptySuggestionsShowStatusWithoutAcceptingClicks() {
        var selection = CandidateSelection()
        selection.update([InputCandidate(text: "See you", language: .english, score: 100)])
        let view = CandidateListView()
        var accepted = false
        view.onSelectPrediction = { accepted = true }
        for message in ["Reading app context…", "Requesting AI prediction…", "The AI returned no continuation."] {
            view.render(selection, predictionStatus: message)
            view.frame = NSRect(origin: .zero, size: view.preferredSize)
            view.layoutSubtreeIfNeeded()
            #expect(!view.predictionButton.isHidden)
            #expect(!view.predictionButton.isEnabled)
            #expect(view.predictionButton.title.contains(message))
            #expect(view.predictionButton.frame.maxY < view.rows[0].frame.minY)
            view.predictionButton.performClick(nil)
        }
        #expect(!accepted)
        #expect(selection.candidate(number: 1)?.text == "See you")
    }

    @MainActor
    @Test func obsoleteRequestCannotReplaceCurrentDiagnosticStatus() {
        let activity = AICompletionActivity()
        let old = activity.begin(.predicting)
        let current = activity.begin(.readingContext)
        #expect(!activity.update(.noSuggestion, requestID: old))
        activity.finishIfPending(requestID: old)
        #expect(activity.phase == .readingContext)
        #expect(activity.update(.ready, requestID: current))
        activity.finishIfPending(requestID: current)
        #expect(activity.phase == .ready)
    }

    @MainActor
    @Test func predictionIsASeparateClickableRowAndDisappearsWhileUpdating() {
        var selection = CandidateSelection()
        selection.update([InputCandidate(text: "See you", language: .english, score: 100)])
        let view = CandidateListView()
        view.render(selection, prediction: "See you tomorrow")
        view.frame = NSRect(origin: .zero, size: view.preferredSize)
        view.layoutSubtreeIfNeeded()

        let button = view.predictionButton
        #expect(!button.isHidden)
        #expect(view.accessibilityChildren()?.last as? NSButton === button)
        #expect(button.frame.maxY < view.rows[0].frame.minY)
        #expect(view.rows.count == 1)
        #expect(selection.candidate(number: 1)?.text == "See you")
        var accepts = 0
        view.onSelectPrediction = { accepts += 1 }
        button.performClick(nil)
        #expect(accepts == 1)
        view.render(selection, isPending: true)
        #expect(button.isHidden)
        #expect(!button.isEnabled)
        #expect(view.accessibilityChildren()?.last as? NSButton !== button)
        button.performClick(nil)
        #expect(accepts == 1)
    }
}

private final class AICompletionTestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.openai.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let responseBody = #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"suffix\":\" tomorrow\"}"}]}]}"#
        guard let url = request.url, url.path == "/v1/responses", request.httpMethod == "POST" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let status = authorization == "Bearer test-denied" ? 401 : 200
        let body = authorization == "Bearer test-oversized" ? Data(repeating: 0x20, count: 65_537) : Data(responseBody.utf8)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
