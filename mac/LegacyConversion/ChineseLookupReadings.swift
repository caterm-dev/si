/// Additional dictionary lookup paths from MSIME's jianpin.rs and syllables.rs (GPL-3.0-only).
/// These retain typed-source spans and do not introduce general spelling correction.
enum ChineseLookupReadings {
    static func splitInitials(_ reading: ChineseReading, input: PinyinInput) -> [ChineseReading] {
        guard input.separators.isEmpty, reading.syllables.count >= 2,
              reading.syllables.contains(where: { ["zh", "ch", "sh"].contains($0) }) else { return [] }
        func split(_ index: Int) -> [(String, Int)] {
            let start = reading.offsets[index]
            return reading.syllables[index].enumerated().map { (String($0.element), start + $0.offset + 1) }
        }
        // Reserve the fully split reading even when the combinations exceed the bound.
        let fullySplit = reading.syllables.indices.flatMap { index -> [(String, Int)] in
            ["zh", "ch", "sh"].contains(reading.syllables[index])
                ? split(index) : [(reading.syllables[index], reading.offsets[index + 1])]
        }
        var paths: [[(String, Int)]] = [[]]
        for index in reading.syllables.indices {
            var next: [[(String, Int)]] = []
            for path in paths {
                next.append(path + [(reading.syllables[index], reading.offsets[index + 1])])
                if next.count == 32 { break }
                if ["zh", "ch", "sh"].contains(reading.syllables[index]) {
                    next.append(path + split(index))
                    if next.count == 32 { break }
                }
            }
            paths = next
        }
        var seen: Set<[String]> = [reading.syllables]
        return ([fullySplit] + paths).compactMap { path in
            let syllables = path.map { $0.0 }
            guard seen.insert(syllables).inserted else { return nil }
            return ChineseReading(syllables: syllables, offsets: [0] + path.map { $0.1 },
                                  isCorrected: reading.isCorrected)
        }.prefix(32).map { $0 }
    }

    static func sparseFallbacks(_ reading: ChineseReading) -> [ChineseReading] {
        let replacements: [([String], Bool)]
        switch reading.syllables.first {
        case "dia": replacements = [(["di", "a"], true), (["di"], false)]
        case "biang": replacements = [(["bi", "ang"], true), (["bi"], false)]
        case "gei": replacements = [(["ge"], false)]
        case "yo": replacements = [(["y"], false)]
        default: return []
        }
        return replacements.map { head, appendRest in
            var syllables = head
            var offsets = [0]
            for piece in head { offsets.append((offsets.last ?? 0) + piece.count) }
            if appendRest {
                syllables += reading.syllables.dropFirst()
                offsets += reading.offsets.dropFirst(2)
            }
            return ChineseReading(syllables: syllables, offsets: offsets, isCorrected: reading.isCorrected)
        }
    }
}
