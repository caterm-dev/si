/// Normalized phonetic input, explicit syllable constraints, and exact source boundaries.
struct PinyinInput {
    let letters: [Character]
    let originalLetters: [Character]
    let separators: Set<Int>
    let rawBoundaries: [Int]
    private let source: [Character]

    init?(_ input: String) {
        guard input.utf8.count <= 256 else { return nil }
        let source = Array(input)
        guard !source.isEmpty, source.first != "'", !input.contains("''") else { return nil }
        var letters: [Character] = []
        var original: [Character] = []
        var separators = Set<Int>()
        var boundaries = [0]
        var position = 0
        while position < source.count {
            let character = source[position]
            if character == "'" {
                separators.insert(letters.count)
                position += 1
                boundaries[boundaries.count - 1] = position
                continue
            }
            let normalized: Character
            if character == "ü" || character == "Ü" {
                normalized = character == "Ü" ? "V" : "v"
            } else if (character == "u" || character == "U"), position + 1 < source.count, source[position + 1] == ":" {
                normalized = character == "U" ? "V" : "v"
                position += 1
            } else { normalized = character }
            guard normalized.isASCII, let lower = normalized.lowercased().first,
                  lower >= "a", lower <= "z" else { return nil }
            letters.append(lower)
            original.append(normalized)
            position += 1
            boundaries.append(position)
            guard letters.count <= 64 else { return nil }
        }
        guard !letters.isEmpty else { return nil }
        self.source = source
        self.letters = letters
        originalLetters = original
        self.separators = separators
        rawBoundaries = boundaries
    }

    func respects(_ boundaries: Set<Int>, from start: Int, to end: Int) -> Bool {
        separators.allSatisfy { $0 <= start || $0 >= end || boundaries.contains($0 - start) }
    }

    func respectsCompletion(_ boundaries: Set<Int>, from start: Int, to end: Int) -> Bool {
        respects(boundaries, from: start, to: end)
            && (!separators.contains(end) || boundaries.contains(end - start))
    }

    func rawText(from start: Int, to end: Int) -> String {
        String(source[rawBoundaries[start]..<rawBoundaries[end]])
    }
}
