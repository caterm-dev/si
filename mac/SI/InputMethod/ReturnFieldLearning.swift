import AppKit
#if SWIFT_PACKAGE
import SICore
#endif

enum ReturnFieldLearning {
    static func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        guard !isRepeat, keyCode == 36 || keyCode == 76 else { return false }
        let shortcut = modifiers.intersection([.command, .control, .option, .shift])
        return shortcut.isEmpty || shortcut == .command
    }

    static func read(isCurrent: () -> Bool, selection: () -> NSRange, markedRange: () -> NSRange,
                     length: () -> Int, text: (NSRange) -> String?) -> String? {
        guard isCurrent() else { return nil }
        let selected = selection()
        guard isCurrent() else { return nil }
        let marked = markedRange()
        guard isCurrent(), marked.location == NSNotFound || marked.length == 0 else { return nil }
        let count = length()
        guard isCurrent(), (0...SentenceLearningStore.maximumBatchBytes).contains(count),
              (0...count).contains(selected.location),
              (0...(count - selected.location)).contains(selected.length) else { return nil }
        if count == 0 { return "" }
        guard let field = text(NSRange(location: 0, length: count)), isCurrent(),
              field.utf16.count == count, field.utf8.count <= SentenceLearningStore.maximumBatchBytes,
              selection() == selected, isCurrent(), markedRange() == marked, isCurrent() else { return nil }
        return field
    }

    static func shouldIngest(before: String, after: String?) -> Bool {
        !before.isEmpty && after?.range(of: before, options: .literal) == nil
    }
}
