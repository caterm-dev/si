import Foundation
import Testing
@testable import SIPresentation

struct PrecedingTextReaderTests {
    private let noMark = NSRange(location: NSNotFound, length: 0)

    @Test func confirmsFieldStartWithoutRequestingHostText() {
        for selection in [NSRange(location: 0, length: 0), NSRange(location: 0, length: 3)] {
            let result = PrecedingTextReader.read(isCurrent: { true }, selection: { selection }, markedRange: { noMark }) { _ in
                Issue.record("An empty committed prefix does not need a host text read.")
                return nil
            }
            #expect(result == "")
        }
        var reads = 0
        #expect(PrecedingTextReader.read(isCurrent: { true }, selection: {
            reads += 1
            return NSRange(location: reads == 1 ? 0 : 1, length: 0)
        }, markedRange: { noMark }) { _ in nil } == nil)
        #expect(PrecedingTextReader.read(isCurrent: { false }, selection: { NSRange(location: 0, length: 0) },
                                       markedRange: { noMark }) { _ in nil } == nil)
    }

    @Test func requestsOnlyTheLastUTF16UnitsExcludingTheSelection() {
        for prefix in ["你好👩‍💻", String(repeating: "树", count: 96), String(repeating: "树", count: 100_000),
                       String(repeating: "a", count: 100_000) + "👩‍💻"] {
            let selection = NSRange(location: prefix.utf16.count, length: 2)
            var requests: [NSRange] = []
            let length = min(prefix.utf16.count, 96)
            let expectedRange = NSRange(location: prefix.utf16.count - length, length: length)
            let expected = (prefix as NSString).substring(with: expectedRange)
            let result = PrecedingTextReader.read(isCurrent: { true }, selection: { selection }, markedRange: { noMark }) { range in
                requests.append(range)
                return (prefix as NSString).substring(with: range)
            }
            #expect(requests == [expectedRange])
            #expect(result?.utf8.elementsEqual(expected.utf8) == true)
        }
    }

    @Test func preservesHostWhitespaceAndUsesTheConfiguredLimit() {
        for prefix in ["want books \t", "你好。   ", "你好\n \t", String(repeating: "a", count: 200) + " \t"] {
            let selection = NSRange(location: prefix.utf16.count, length: 0)
            let length = min(prefix.utf16.count, 96)
            let range = NSRange(location: prefix.utf16.count - length, length: length)
            let expected = (prefix as NSString).substring(with: range)
            let result = PrecedingTextReader.read(isCurrent: { true }, selection: { selection }, markedRange: { noMark }) { requested in
                #expect(requested == range)
                return expected
            }
            #expect(result?.utf8.elementsEqual(expected.utf8) == true)
        }
        let prefix = "some earlier text before the caret"
        let selection = NSRange(location: prefix.utf16.count, length: 0)
        let result = PrecedingTextReader.read(isCurrent: { true }, selection: { selection }, markedRange: { noMark },
                                             utf16Limit: 8) { range in
            #expect(range == NSRange(location: prefix.utf16.count - 8, length: 8))
            return (prefix as NSString).substring(with: range)
        }
        #expect(result == "he caret")
    }

    @Test func skipsUnavailableAndStaleContexts() {
        let caret = NSRange(location: 2, length: 0)
        for (selection, mark) in [(noMark, noMark), (caret, NSRange(location: 1, length: 1))] {
            #expect(PrecedingTextReader.read(isCurrent: { true }, selection: { selection }, markedRange: { mark }) { _ in
                Issue.record("Unsupported ranges must not read host text.")
                return "你好"
            } == nil)
        }
        #expect(PrecedingTextReader.read(isCurrent: { true }, selection: { caret }, markedRange: { noMark }) { _ in "你" } == nil)
        var current = true
        #expect(PrecedingTextReader.read(isCurrent: { current }, selection: { caret }, markedRange: { noMark }) { _ in
            current = false
            return "你好"
        } == nil)
        var selection = caret
        #expect(PrecedingTextReader.read(isCurrent: { true }, selection: { selection }, markedRange: { noMark }) { _ in
            selection.location = 0
            return "你好"
        } == nil)
    }
}
