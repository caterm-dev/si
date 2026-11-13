import Foundation

/// A normalized finite spelling channel with sixteen times the geometric mass at the
/// exact endpoint. Incomplete observations still halve in weight per missing letter.
/// This shared heuristic favors completed spellings without reserving ranking tiers.
enum SpellingMatchChannel {
    static let exactMatchAdvantage = 4.0
    private static let offsets = (0...64).map {
        log2(1 + (1 - exp2(-Double($0))) / exp2(exactMatchAdvantage))
    }

    static func cost(missingLetters: Int, maximumMissingLetters: Int) -> Double {
        precondition((0...64).contains(maximumMissingLetters)
            && (0...maximumMissingLetters).contains(missingLetters))
        return offsets[maximumMissingLetters]
            + (missingLetters == 0 ? 0 : exactMatchAdvantage + Double(missingLetters))
    }
}

/// English observes nonempty word prefixes; the complete word has extra spelling weight.
enum WordPrefixChannel {
    static func cost(fullLength: Int, typedLength: Int) -> Double {
        precondition(fullLength > 0 && fullLength <= 64 && typedLength > 0 && typedLength <= fullLength)
        return SpellingMatchChannel.cost(missingLetters: fullLength - typedLength,
                                         maximumMissingLetters: fullLength - 1)
    }
}
