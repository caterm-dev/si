import Foundation
import Observation
#if SWIFT_PACKAGE
import SILocalization
#endif

/// Shared diagnostic metadata only. Composition, suggestions and host text stay client-local.
@MainActor
@Observable
final class AICompletionActivity {
    static let shared = AICompletionActivity()

    enum Phase: Equatable {
        case appUnavailable, secureInput, languagesDisabled
        case waitingForCandidates, selectWholeCandidate, moveCaretToEnd
        case readingContext, predicting, noSuggestion, ready
        case contextChanged, cancelled, failed

        var message: String {
            switch self {
            case .appUnavailable: L10n.text("Waiting for the input app to become active.")
            case .secureInput: L10n.text("AI completion is unavailable during secure input.")
            case .languagesDisabled: L10n.text("Enable an input language to use AI completion.")
            case .waitingForCandidates: L10n.text("Waiting for ordinary candidates…")
            case .selectWholeCandidate: L10n.text("Select a complete candidate for AI completion.")
            case .moveCaretToEnd: L10n.text("Move to the end of the composition for AI completion.")
            case .readingContext: L10n.text("Reading app context…")
            case .predicting: L10n.text("Requesting AI prediction…")
            case .noSuggestion: L10n.text("The AI returned no continuation.")
            case .ready: L10n.text("AI suggestion ready. Press Tab to accept.")
            case .contextChanged: L10n.text("App context changed. The suggestion was discarded.")
            case .cancelled: L10n.text("Prediction cancelled after an input or focus change.")
            case .failed: L10n.text("AI completion failed. See the error below.")
            }
        }
    }

    private(set) var phase: Phase?
    private var requestID: UUID?

    @discardableResult
    func begin(_ phase: Phase) -> UUID {
        let id = UUID()
        requestID = id
        self.phase = phase
        return id
    }

    @discardableResult
    func update(_ phase: Phase, requestID: UUID) -> Bool {
        guard self.requestID == requestID else { return false }
        self.phase = phase
        return true
    }

    func finishIfPending(requestID: UUID) {
        guard self.requestID == requestID,
              phase == .readingContext || phase == .predicting else { return }
        phase = .contextChanged
    }
}
