import AppKit

enum ReturnFieldLearning {
    private static let fieldLimit = 2_048

    static func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        guard !isRepeat, keyCode == 36 || keyCode == 76 else { return false }
        let shortcut = modifiers.intersection([.command, .control, .option, .shift])
        return shortcut.isEmpty || shortcut == .command
    }

    static func read(isCurrent: () -> Bool, selection: () -> NSRange, markedRange: () -> NSRange,
                     text: (NSRange) -> String?,
                     textWithActualRange: (NSRange) -> (text: String, range: NSRange)?) -> String? {
        guard isCurrent() else { return nil }
        let marked = markedRange()
        guard isCurrent(), marked.location == NSNotFound || marked.length == 0 else { return nil }
        let range = NSRange(location: 0, length: fieldLimit)
        let response = textWithActualRange(range)
        if let response, response.range.location == 0, (1...fieldLimit).contains(response.range.length),
           response.text.utf16.count == response.range.length {
            return response.text
        }
        if response == nil, isCurrent(), let value = text(range), (1...fieldLimit).contains(value.utf16.count) {
            return value
        }

        // Some clients reject a fixed range extending beyond their text.
        guard isCurrent() else { return nil }
        let caret = selection()
        guard isCurrent(), caret.length == 0, (1...fieldLimit).contains(caret.location),
              let prefix = text(NSRange(location: 0, length: caret.location)),
              (1...fieldLimit).contains(prefix.utf16.count) else { return nil }
        return prefix
    }

    static func shouldIngest(before: String, after: String?) -> Bool {
        !before.isEmpty && after?.range(of: before, options: .literal) == nil
    }
}
