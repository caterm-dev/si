import Testing
import SICore

struct SentenceSnapshotTests {
    @Test func acceptsLongMultilineTextAndRejectsBlankFields() {
        #expect(SentenceSnapshot.accepts("你好👩‍💻\n\t" + String(repeating: "学", count: 2_000)))
        for blank in ["", " \n\t", "\0"] {
            #expect(!SentenceSnapshot.accepts(blank))
        }
    }
}
