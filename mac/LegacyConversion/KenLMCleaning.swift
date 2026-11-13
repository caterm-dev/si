import Foundation

enum KenLMCleaning {
    static let version = "si-kenlm-cleaning-v1"
    static let moduleSHA = "c8f370f66310e2e3b5ceab7fa001b8d28d995f2d183557f4425a1a7a9abb5596"
    static let vectorsSHA = "c6b45ddb37eaa652a4c3deafbc4467e2913ea55f19301c85600beb62d392b1e4"
    private static let reserved: Set<String> = ["<s>", "</s>", "<unk>"]

    // Python 3.12's Unicode 15.0 decimal-digit ranges. Freeze them across OS upgrades.
    private static let decimalStarts: [UInt32] = [
        0x30, 0x660, 0x6F0, 0x7C0, 0x966, 0x9E6, 0xA66, 0xAE6,
        0xB66, 0xBE6, 0xC66, 0xCE6, 0xD66, 0xDE6, 0xE50, 0xED0,
        0xF20, 0x1040, 0x1090, 0x17E0, 0x1810, 0x1946, 0x19D0, 0x1A80,
        0x1A90, 0x1B50, 0x1BB0, 0x1C40, 0x1C50, 0xA620, 0xA8D0, 0xA900,
        0xA9D0, 0xA9F0, 0xAA50, 0xABF0, 0xFF10, 0x104A0, 0x10D30, 0x11066,
        0x110F0, 0x11136, 0x111D0, 0x112F0, 0x11450, 0x114D0, 0x11650, 0x116C0,
        0x11730, 0x118E0, 0x11950, 0x11C50, 0x11D50, 0x11DA0, 0x11F50, 0x16A60,
        0x16AC0, 0x16B50, 0x1D7CE, 0x1D7D8, 0x1D7E2, 0x1D7EC, 0x1D7F6, 0x1E140,
        0x1E2F0, 0x1E4F0, 0x1E950, 0x1FBF0,
    ]

    static func rejects(_ text: String) -> Bool {
        ["\u{fffd}", "锟斤拷", "烫烫烫", "屯屯屯"].contains { text.contains($0) }
    }

    static func baseToken(_ token: String) -> String? {
        guard !reserved.contains(token) else { return nil }
        if isNumber(token) { return "<num>" }
        return token.unicodeScalars.count > 32 ? "<oov>" : token
    }

    static func line(_ text: String, count: (Data) -> Int, protected: (Data) -> Bool,
                     threshold: Int) -> [String]? {
        guard !rejects(text) else { return nil }
        var result: [String] = []
        for part in text.unicodeScalars.split(whereSeparator: isWhitespace) {
            guard let token = baseToken(String(part)) else { return nil }
            let key = Data(token.utf8)
            result.append(token != "<num>" && token != "<oov>" && threshold > 0
                && !protected(key) && count(key) < threshold ? "<oov>" : token)
        }
        return result
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 9...13, 28...32, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029,
             0x202F, 0x205F, 0x3000: true
        default: false
        }
    }

    private static func isNumber(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        func take(_ values: UInt32...) -> Bool {
            guard index != scalars.endIndex, values.contains(scalars[index].value) else { return false }
            scalars.formIndex(after: &index)
            return true
        }
        func digits() -> Bool {
            let start = index
            while index != scalars.endIndex {
                let value = scalars[index].value
                guard (48...57).contains(value) || (value > 127 && decimalStarts.contains(where: {
                    value >= $0 && value - $0 < 10
                })) else { break }
                scalars.formIndex(after: &index)
            }
            return index != start
        }
        _ = take(43, 45)
        let integer = digits()
        let fraction = take(46) ? digits() : false
        guard integer || fraction else { return false }
        if take(69, 101) {
            _ = take(43, 45)
            guard digits() else { return false }
        }
        return index == scalars.endIndex
    }
}
