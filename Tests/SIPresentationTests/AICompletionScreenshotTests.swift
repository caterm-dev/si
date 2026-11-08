import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import SIPresentation

struct AICompletionScreenshotTests {
    @Test func tabRequestsThenAcceptsAndOrdinaryTypingNeverRequests() {
        func action(_ key: UInt16 = 48, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false,
                    composing: Bool = true, suggestion: Bool = false, pending: Bool = false) -> AICompletionTabAction? {
            AICompletionTabAction.resolve(keyCode: key, modifiers: flags, isRepeat: repeatKey,
                enabled: true, composing: composing, hasSuggestion: suggestion, pending: pending)
        }
        #expect(action() == .request)
        #expect(action(pending: true) == .wait)
        #expect(action(suggestion: true) == .accept)
        #expect(action(repeatKey: true, suggestion: true) == .wait)
        #expect(action(composing: false) == nil)
        #expect(action(flags: .shift) == nil)
        #expect(action(flags: .command) == nil)
        for key: UInt16 in [0, 1, 2, 49, 51, 36] { #expect(action(key) == nil) }
    }

    @Test func capturesOnlyTheInputAppsFrontWindowAndSkipsPanels() throws {
        func record(_ id: Int, pid: Int, layer: Int = 0) -> [String: Any] {
            [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid),
             kCGWindowLayer as String: layer, kCGWindowAlpha as String: 1.0,
             kCGWindowBounds as String: CGRect(x: 10, y: 20, width: 500, height: 400).dictionaryRepresentation]
        }
        let records = [record(1, pid: 100, layer: 3), record(2, pid: 200), record(3, pid: 100), record(4, pid: 100)]
        let window = try #require(AICompletionScreenshot.selectWindow(records: records, pid: 100))
        #expect(window.id == 3)
        #expect(window.pid == 100)
        let floating = try #require(AICompletionScreenshot.selectWindow(records: records, pid: 100, level: 3))
        #expect(floating.id == 1)
        #expect(floating.level == 3)
        // A host-reported level need not exist in Window Server's records.
        #expect(AICompletionScreenshot.selectWindow(records: records, pid: 100, level: 8)?.id == 3)
        #expect(AICompletionScreenshot.selectWindow(records: [records[0]], pid: 100, level: 8)?.id == 1)
        #expect(AICompletionScreenshot.selectWindow(records: records, pid: 300) == nil)
    }

    @Test func claudeReceivesAnImageContentBlockAndNoAXData() throws {
        let png = Data([1, 2, 3])
        let data = try AICompletionProvider.claudeInput(prompt: "synthetic prompt", screenshot: png)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["type"] as? String == "user")
        let message = try #require(body["message"] as? [String: Any])
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "synthetic prompt")
        let source = try #require(content.last?["source"] as? [String: String])
        #expect(source["media_type"] == "image/png")
        #expect(Data(base64Encoded: source["data"] ?? "") == png)
        let context = AICompletionContext(currentInput: "nihao", candidate: "你好", fieldBefore: "前文", fieldAfter: "后文")
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any])
        #expect(encoded["accessibilityTree"] == nil)
        #expect(encoded["fieldBefore"] as? String == "前文")
    }
}
