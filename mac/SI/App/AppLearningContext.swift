import InputMethodKit

/// Identity only. Composition buffers and candidate selection remain controller-local.
@MainActor
final class AppLearningContext {
    static let shared = AppLearningContext()
    private weak var client: (any IMKTextInput)?
    private(set) var bundle: String?
    private(set) var generation: UInt64 = 0

    func update(_ client: any IMKTextInput) {
        guard (self.client as AnyObject?) !== (client as AnyObject) else { return }
        self.client = client
        bundle = client.bundleIdentifier()
        generation &+= 1
    }

    func clear(_ client: Any?) {
        guard client == nil || (self.client as AnyObject?) === (client as AnyObject?) else { return }
        self.client = nil
        bundle = nil
        generation &+= 1
    }

    var hasClient: Bool { client != nil }
}
