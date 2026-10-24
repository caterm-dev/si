import Foundation
import Testing
@testable import SICore

struct SpellingEvidenceTests {
    @Test func chineseSpellingIsNormalizedPerSyllableAndIndependentOfWordSegmentation() {
        for length in 1...64 {
            let mass = (0...length).reduce(0.0) {
                $0 + exp2(-PinyinSpellingChannel.cost(length: length, typedLength: $1))
            }
            #expect(abs(mass - 1) < 1e-12)
            #expect(PinyinSpellingChannel.cost(length: length, typedLength: length)
                    < PinyinSpellingChannel.cost(length: length, typedLength: length - 1))
            #expect(abs(PinyinSpellingChannel.cost(length: length, typedLength: length - 1)
                - PinyinSpellingChannel.cost(length: length, typedLength: length) - 5) < 1e-12)
        }
        let whole = PinyinSpellingChannel.cost(syllables: ["di", "er", "ye"], typedLength: 6)
        let split = ["di", "er", "ye"].reduce(0.0) {
            $0 + PinyinSpellingChannel.cost(syllables: [$1], typedLength: $1.count)
        }
        #expect(whole == split)
        #expect(whole < PinyinSpellingChannel.cost(syllables: ["di", "er", "yue", "er"], typedLength: 6))
        #expect(PinyinSpellingChannel.cost(syllables: ["ni", "hao"], typedLength: 5)
                < PinyinSpellingChannel.cost(syllables: ["ni", "hao"], typedLength: 4))
    }
}
