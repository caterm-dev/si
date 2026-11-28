import Foundation

enum SettingsPage: Hashable {
    case typing
    case aiCompletion
    case directInput
    case phrases
    case learning
    case appLearning
    case inputHistory
    case permissions
    case about

    static let groups: [(title: String, pages: [Self])] = [
        ("Input", [.typing, .aiCompletion, .directInput]),
        ("Personal Data", [.phrases, .learning, .appLearning, .inputHistory]),
        ("System", [.permissions, .about])
    ]

    var title: String {
        switch self {
        case .typing: "Typing"
        case .aiCompletion: "AI Completion"
        case .directInput: "Direct Input by Application"
        case .phrases: "Personal Phrases"
        case .learning: "Personal Learning"
        case .appLearning: "App Learning"
        case .inputHistory: "Input History"
        case .permissions: "Experimental Permissions"
        case .about: "About SI"
        }
    }

    var sidebarTitle: String {
        switch self {
        case .directInput: "Direct Input"
        case .permissions: "Permissions"
        default: title
        }
    }

    var icon: String {
        switch self {
        case .typing: "keyboard"
        case .aiCompletion: "sparkles.rectangle.stack"
        case .directInput: "macwindow"
        case .phrases: "text.badge.plus"
        case .learning: "sparkles"
        case .appLearning: "app.connected.to.app.below.fill"
        case .inputHistory: "clock"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }

    func matches(_ query: String) -> Bool {
        let keys = [title, sidebarTitle] + searchKeys
        return query.isEmpty || keys.contains {
            L10n.text($0).localizedStandardContains(query) || $0.localizedStandardContains(query)
        }
    }

    private var searchKeys: [String] {
        switch self {
        case .typing:
            ["Languages", "English", "Chinese (Simplified)",
             "Local model ranking", "Use large ranking model",
             "Show punctuation candidates", "Punctuation during composition"] + PunctuationBehavior.allCases.map(\.displayName)
        case .aiCompletion: ["Enable AI Completion", "Codex CLI", "Claude Code", "OpenAI API Key", "Accessibility"]
        case .directInput: ["Manage Direct Input…", "Applications", "Terminal", "Toggle Direct Input Shortcut", "Record Shortcut…"]
        case .phrases: ["Add Phrase…", "Edit", "Delete", "Delete All…", "Frequency", "user.silex"]
        case .learning: ["Manage Learning Data…", "Clear Personal Learning Data…"]
        case .appLearning: ["Enable App Learning", "Accessibility", "Saved App Data", "Clear All App Learning Data…"]
        case .inputHistory: ["Save Input History", "Export Input History…", "Clear Input History…"]
        case .permissions: ["Accessibility", "Screen Recording"]
        case .about: ["Software Updates", "Check for Updates…", "Version", "Keyboard Shortcuts", "GitHub"]
        }
    }
}
