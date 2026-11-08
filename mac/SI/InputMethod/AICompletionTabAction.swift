import AppKit

enum AICompletionTabAction: Equatable {
    case request, accept, wait

    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool,
                        enabled: Bool, composing: Bool, hasSuggestion: Bool, pending: Bool) -> Self? {
        guard enabled, composing, keyCode == 48,
              modifiers.intersection([.shift, .command, .control, .option]).isEmpty else { return nil }
        if isRepeat { return .wait }
        if hasSuggestion { return .accept }
        return pending ? .wait : .request
    }
}
