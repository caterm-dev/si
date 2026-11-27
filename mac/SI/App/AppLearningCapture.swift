import ApplicationServices
import Carbon
import Foundation

/// A focused-window AX read. No screenshots, clipboard, actions, raw-file exports or app activation.
actor AppLearningCapture {
    enum Failure: Error { case unavailable, incomplete, obsolete, secure }
    struct Snapshot: Sendable {
        let paragraphs: [String]
    }
    private let pid: pid_t
    private let validate: @MainActor @Sendable () -> Bool
    private var visited: [CFHashCode: [AXUIElement]] = [:]
    private var bytes = 0
    private let controls: Set<String> = ["AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXComboBox",
                                         "AXMenu", "AXMenuBar", "AXMenuItem", "AXMenuBarItem", "AXToolbar", "AXImage"]

    init(pid: pid_t, validate: @escaping @MainActor @Sendable () -> Bool) {
        self.pid = pid
        self.validate = validate
    }

    func capture() async throws -> Snapshot {
        guard await validate() else { throw Failure.obsolete }
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 0.2)
        try checkFocus(app)
        guard let window = element(try attribute(app, kAXFocusedWindowAttribute)) else { throw Failure.unavailable }
        _ = AXUIElementSetMessagingTimeout(window, 0.2)
        let paragraphs = try await read(window)
        guard await validate(), let current = element(try attribute(app, kAXFocusedWindowAttribute)), CFEqual(window, current) else {
            throw Failure.obsolete
        }
        try checkFocus(app)
        return Snapshot(paragraphs: paragraphs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private enum Work {
        case visit(AXUIElement, inline: Bool)
        case children(AXUIElement, index: Int, count: Int, inline: Bool)
        case finishGroup(Int)
    }

    private func read(_ root: AXUIElement) async throws -> [String] {
        var work: [Work] = [.visit(root, inline: false)]
        var paragraphs: [String] = []
        var operations = 0
        while let item = work.popLast() {
            try Task.checkCancellation()
            guard !IsSecureEventInputEnabled() else { throw Failure.secure }
            if operations % 16 == 0, !(await validate()) { throw Failure.obsolete }
            operations &+= 1
            switch item {
            case .finishGroup(let start):
                if paragraphs.count - start > 1 {
                    let joined = paragraphs[start...].joined()
                    paragraphs.removeSubrange(start...)
                    paragraphs.append(joined)
                }
            case .children(let parent, let index, let count, let inline):
                // Page traversal work; page size does not reject or truncate a snapshot.
                let length = min(64, count - index)
                var raw: CFArray?
                guard AXUIElementCopyAttributeValues(parent, kAXChildrenAttribute as CFString, index, length, &raw) == .success,
                      let children = raw as? [AXUIElement], children.count == length else { throw Failure.incomplete }
                if index + length < count { work.append(.children(parent, index: index + length, count: count, inline: inline)) }
                work += children.reversed().map { .visit($0, inline: inline) }
            case .visit(let value, let inline):
                var owner: pid_t = 0
                guard AXUIElementGetPid(value, &owner) == .success, owner == pid else { throw Failure.incomplete }
                _ = AXUIElementSetMessagingTimeout(value, 0.2)
                let hash = CFHash(value)
                if visited[hash, default: []].contains(where: { CFEqual($0, value) }) { continue }
                visited[hash, default: []].append(value)
                let role = string(try attribute(value, kAXRoleAttribute))
                guard !role.isEmpty else { throw Failure.incomplete }
                let subrole = string(try attribute(value, kAXSubroleAttribute))
                if subrole == kAXSecureTextFieldSubrole as String || controls.contains(role) { continue }
                if try attribute(value, "AXHidden") as? Bool == true { continue }
                let classes = try attribute(value, "AXDOMClassList") as? [String] ?? []
                if classes.contains("sr-only") || classes.contains("visually-hidden") { continue }
                if ["AXStaticText", "AXTextArea", "AXTextField", "AXSearchField", "AXListMarker"].contains(role) {
                    try appendText(string(try attribute(value, kAXValueAttribute)), to: &paragraphs)
                    continue
                }
                var count = 0
                let error = AXUIElementGetAttributeValueCount(value, kAXChildrenAttribute as CFString, &count)
                if error == .attributeUnsupported || error == .noValue { continue }
                guard error == .success, count >= 0 else { throw Failure.incomplete }
                if count == 0 {
                    try appendText(string(try attribute(value, kAXValueAttribute)), to: &paragraphs)
                    continue
                }
                let paragraph = role == "AXParagraph" || role == "AXHeading"
                    || classes.contains(where: { $0.lowercased().hasPrefix("paragraph-") })
                let style = ["AXStrongStyleGroup", "AXEmphasisStyleGroup", "AXCodeStyleGroup"].contains(subrole)
                let joined = inline || paragraph || style || role == "AXLink"
                if joined { work.append(.finishGroup(paragraphs.count)) }
                work.append(.children(value, index: 0, count: count, inline: joined || role == "AXList"))
            }
        }
        return paragraphs
    }

    private func appendText(_ text: String, to paragraphs: inout [String]) throws {
        guard !text.isEmpty else { return }
        bytes += text.utf8.count
        guard bytes <= RustAppLearning.maximumSnapshotBytes else { throw Failure.incomplete }
        paragraphs.append(text)
    }

    private func checkFocus(_ app: AXUIElement) throws {
        guard !IsSecureEventInputEnabled() else { throw Failure.secure }
        if let focused = element(try attribute(app, kAXFocusedUIElementAttribute)) {
            _ = AXUIElementSetMessagingTimeout(focused, 0.2)
            if string(try attribute(focused, kAXSubroleAttribute)) == kAXSecureTextFieldSubrole as String { throw Failure.secure }
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if result == .attributeUnsupported || result == .noValue { return nil }
        guard result == .success else { throw Failure.incomplete }
        return value
    }
    private func string(_ value: CFTypeRef?) -> String {
        if let value = value as? String { return value }
        return (value as? NSAttributedString)?.string ?? ""
    }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
