import AppKit
import Testing
@testable import SIPresentation

struct CandidateBoundaryReaderTests {
    @Test func knownMarkedRangeNeedsOnlyTheCommittedPrefix() throws {
        let marked = NSRange(location: 2, length: 5)
        var requests: [NSRange] = []
        let boundary = try #require(CandidateBoundaryReader.read(
            markedText: "hello", cursorUTF16Offset: 5, isCurrent: { true },
            selection: { NSRange(location: 7, length: 0) }, markedRange: { marked }, text: { range in
                requests.append(range)
                // A host may expose committed text while keeping its inline spelling private.
                return range == NSRange(location: 0, length: 2) ? "中文" : nil
            }))
        #expect(boundary == "中文")
        #expect(requests == [NSRange(location: 0, length: 2)])
    }

    @Test func nativeReadMayReturnACoveringRange() throws {
        let marked = NSRange(location: 2, length: 5)
        for reported in [marked, NSRange(location: NSNotFound, length: 0)] {
            let boundary = try #require(CandidateBoundaryReader.read(
                markedText: "hello", cursorUTF16Offset: 5, isCurrent: { true },
                selection: { NSRange(location: 7, length: 0) }, markedRange: { reported },
                textWithActualRange: { _ in ("中文hello", NSRange(location: 0, length: 7)) }, text: { _ in nil }))
            #expect(boundary == "中文")
        }
    }

    @Test func expandedNativeRangePreservesTheAdjacentCharacterWhenTheRequestCutsASurrogate() throws {
        let marked = NSRange(location: 5, length: 5)
        let boundary = try #require(CandidateBoundaryReader.read(
            markedText: "hello", cursorUTF16Offset: 5, isCurrent: { true },
            selection: { NSRange(location: 10, length: 0) }, markedRange: { marked },
            textWithActualRange: { range in
                #expect(range == NSRange(location: 1, length: 4))
                return ("𠀀xy文", NSRange(location: 0, length: 5))
            }, text: { _ in nil }))
        #expect(boundary.last == "文")
    }

    @Test func nativeReadRejectsNoncoveringOrInconsistentRanges() {
        for response in [("中", NSRange(location: 0, length: 1)), ("中文", NSRange(location: 1, length: 2)),
                         ("中文", NSRange(location: 0, length: 3)), ("中文", NSRange(location: NSNotFound, length: 2))] {
            #expect(CandidateBoundaryReader.read(markedText: "hello", cursorUTF16Offset: 5,
                isCurrent: { true }, selection: { NSRange(location: 7, length: 0) },
                markedRange: { NSRange(location: 2, length: 5) },
                textWithActualRange: { _ in response }, text: { _ in nil }) == nil)
        }
    }

    @Test func knownMarkedRangeDoesNotRequireAnAvailableSelection() throws {
        let marked = NSRange(location: 2, length: 5)
        let field = "中文hello" as NSString
        let boundary = try #require(CandidateBoundaryReader.read(
            markedText: "hello", cursorUTF16Offset: 5, isCurrent: { true },
            selection: { NSRange(location: NSNotFound, length: NSNotFound) }, markedRange: { marked },
            text: { field.substring(with: $0) }))
        #expect(boundary == "中文")
        #expect(CandidateBoundaryReader.read(markedText: "hello", cursorUTF16Offset: 5,
            isCurrent: { true }, selection: { NSRange(location: NSNotFound, length: NSNotFound) },
            markedRange: { NSRange(location: NSNotFound, length: NSNotFound) },
            text: { _ in Issue.record("Missing positioning must not read host text."); return nil }) == nil)
    }

    @Test @MainActor func nativeTextViewReadbackValidatesDerivedMarkedRange() throws {
        let view = NSTextView()
        view.string = "中文"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.setMarkedText("hel lo", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        let boundary = try #require(CandidateBoundaryReader.read(
            markedText: "hel lo", cursorUTF16Offset: 3, isCurrent: { true },
            selection: view.selectedRange, markedRange: { NSRange(location: NSNotFound, length: 0) },
            textWithActualRange: { range in
                var actual = NSRange(location: NSNotFound, length: 0)
                guard let value = view.attributedSubstring(forProposedRange: range, actualRange: &actual) else { return nil }
                return (value.string, actual)
            }, text: { _ in nil }))
        #expect(boundary == "中文")
    }

    @Test func nativeTextFallbackSupportsUnavailableAttributedTextAndMarkedRange() throws {
        let field = "中文hel lo" as NSString
        let marked = NSRange(location: 2, length: 6)
        for reported in [marked, NSRange(location: NSNotFound, length: NSNotFound), NSRange(location: 2, length: 0)] {
            var requests: [NSRange] = []
            let boundary = try #require(CandidateBoundaryReader.read(
                markedText: "hel lo", cursorUTF16Offset: 3, isCurrent: { true },
                selection: { NSRange(location: 5, length: 0) }, markedRange: { reported },
                textWithActualRange: { range in
                    requests.append(range)
                    return (field.substring(with: range), range)
                }, text: { _ in nil }))
            #expect(boundary == "中文")
            #expect(requests == (reported == marked ? [NSRange(location: 0, length: 2)]
                : [marked, NSRange(location: 0, length: 2)]))
        }
    }

    @Test func nativeFallbackRejectsWrongRangesAndUnverifiedSpelling() {
        let marked = NSRange(location: 2, length: 5)
        for wrongRange in [true, false] {
            let boundary = CandidateBoundaryReader.read(markedText: "hello", cursorUTF16Offset: 5,
                isCurrent: { true }, selection: { NSRange(location: 7, length: 0) },
                markedRange: { NSRange(location: NSNotFound, length: 0) },
                textWithActualRange: { range in
                    #expect(range == marked)
                    return wrongRange ? ("hello", NSRange(location: 1, length: 5)) : ("other", range)
                }, text: { _ in nil })
            #expect(boundary == nil)
        }
    }

    @Test func nativeFallbackRejectsReentrantFocusOrMarkedRangeChanges() {
        let marked = NSRange(location: 2, length: 5)
        for changesFocus in [true, false] {
            var current = true
            var reported = NSRange(location: NSNotFound, length: 0)
            #expect(CandidateBoundaryReader.read(markedText: "hello", cursorUTF16Offset: 5,
                isCurrent: { current }, selection: { NSRange(location: 7, length: 0) }, markedRange: { reported },
                textWithActualRange: { range in
                    if range == marked { return ("hello", range) }
                    if changesFocus { current = false } else { reported = marked }
                    return ("中文", range)
                }, text: { _ in nil }) == nil)
        }
    }

    @Test func readsOutsideTheEntireMarkedRangeRegardlessOfCaretPosition() throws {
        for before in ["", "中文", "👩‍💻𠀀", "文\u{E0100}", "中文 "] {
            let markedText = "hel lo"
            let field = (before + markedText + " 后文") as NSString
            let marked = NSRange(location: before.utf16.count, length: markedText.utf16.count)
            let selection = NSRange(location: marked.location + 2, length: 0)
            var requests: [NSRange] = []
            let boundary = try #require(CandidateBoundaryReader.read(
                markedText: markedText, cursorUTF16Offset: 2, isCurrent: { true },
                selection: { selection }, markedRange: { marked }, text: { range in
                    requests.append(range)
                    return field.substring(with: range)
                }))
            #expect(boundary == String(decoding: Array(before.utf16.suffix(4)), as: UTF16.self))
            #expect(requests.allSatisfy { $0 == marked || $0.length <= 4 })
            #expect(requests.allSatisfy { NSMaxRange($0) <= NSMaxRange(marked) })
        }
    }

    @Test func unavailablePrecedingTextReturnsNoContext() {
        let marked = NSRange(location: 2, length: 5)
        let boundary = CandidateBoundaryReader.read(
            markedText: "hello", cursorUTF16Offset: 5, isCurrent: { true },
            selection: { NSRange(location: 7, length: 0) }, markedRange: { marked },
            text: { $0 == marked ? "hello" : nil })
        #expect(boundary == nil)
    }

    @Test func rejectsInvalidRangesAndInlineText() {
        let valid = NSRange(location: 2, length: 5)
        for marked in [NSRange(location: NSNotFound, length: 0), NSRange(location: 0, length: 0),
                       NSRange(location: -1, length: 5), NSRange(location: Int.max - 2, length: 5)] {
            #expect(CandidateBoundaryReader.read(markedText: "hello", cursorUTF16Offset: 5,
                isCurrent: { true }, selection: { valid }, markedRange: { marked }, text: { _ in
                    Issue.record("Invalid ranges must not read host text.")
                    return nil
                }) == nil)
        }
        #expect(CandidateBoundaryReader.read(markedText: "hello", cursorUTF16Offset: 5,
            isCurrent: { true }, selection: { NSRange(location: 7, length: 0) },
            markedRange: { NSRange(location: NSNotFound, length: 0) },
            text: { _ in "other" }) == nil)
        #expect(CandidateBoundaryReader.read(markedText: "hello", cursorUTF16Offset: 5,
            isCurrent: { true }, selection: { NSRange(location: 3, length: 0) }, markedRange: { valid },
            text: { _ in Issue.record("A stale caret must not read host text."); return nil }) == nil)
    }

    @Test func rejectsReentrantChangesDuringHostReads() {
        let marked = NSRange(location: 2, length: 5)
        for invalidatesCurrent in [true, false] {
            var current = true
            var caret = NSRange(location: 7, length: 0)
            #expect(CandidateBoundaryReader.read(markedText: "hello", cursorUTF16Offset: 5,
                isCurrent: { current }, selection: { caret }, markedRange: { marked }, text: { range in
                    if range == marked { return "hello" }
                    if invalidatesCurrent { current = false } else { caret.location = 0 }
                    return "中文"
                }) == nil)
        }
    }
}
