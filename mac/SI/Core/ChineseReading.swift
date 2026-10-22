/// One reading with exact normalized-source boundaries, including spelling aliases.
struct ChineseReading: Equatable, Sendable {
    let syllables: [String]
    let offsets: [Int]
    let isCorrected: Bool

    init(syllables: [String]) {
        self.syllables = syllables
        var offsets = [0]
        for syllable in syllables { offsets.append((offsets.last ?? 0) + syllable.count) }
        self.offsets = offsets
        isCorrected = false
    }

    init(syllables: [String], offsets: [Int], isCorrected: Bool) {
        self.syllables = syllables
        self.offsets = offsets
        self.isCorrected = isCorrected
    }
}
