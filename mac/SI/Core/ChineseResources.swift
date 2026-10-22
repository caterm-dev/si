import Foundation

/// Packaged, immutable Chinese data. No network access or user archive is involved.
enum ChineseResources {
    static func url(_ name: String, extension suffix: String) -> URL? {
        DictionaryResources.url(name, extension: suffix, languageDirectory: "Chinese")
    }
}

/// Read-only MSNG v1 tables, compatible with the pinned MSIME dictionary builder.
/// Data and the bucket index are immutable after initialization and shared by both search stages.
struct ChineseNgramTable: Sendable {
    private let data: Data
    private let count: Int
    private let buckets: [Int]

    init?(url: URL?) {
        guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 16,
              Array(data.prefix(4)) == [77, 83, 78, 71] else { return nil }
        func word(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        let count = Int(word(8))
        guard word(4) == 1, count <= 40_000_000, data.count >= 16 + count * 12 else { return nil }
        var buckets = [Int]()
        buckets.reserveCapacity(65_537)
        var previous: UInt64 = 0
        for index in 0..<count {
            let key = data.withUnsafeBytes {
                UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 16 + index * 8, as: UInt64.self))
            }
            guard index == 0 || key >= previous else { return nil }
            previous = key
            let bucket = Int(key >> 48)
            while buckets.count <= bucket { buckets.append(index) }
        }
        buckets.append(contentsOf: repeatElement(count, count: 65_537 - buckets.count))
        self.data = data
        self.count = count
        self.buckets = buckets
    }

    func score(_ words: [String]) -> Double {
        var key: UInt64 = 0xcbf29ce484222325
        for (index, word) in words.enumerated() {
            if index > 0 { key = key &* 0x100000001b3 }
            for byte in word.utf8 { key = (key ^ UInt64(byte)) &* 0x100000001b3 }
        }
        let bucket = Int(key >> 48)
        var lower = buckets[bucket], upper = buckets[bucket + 1]
        return data.withUnsafeBytes { bytes in
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                let value = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 16 + middle * 8, as: UInt64.self))
                if value < key { lower = middle + 1 } else { upper = middle }
            }
            guard lower < buckets[bucket + 1],
                  UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 16 + lower * 8, as: UInt64.self)) == key else { return 0 }
            let bits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 16 + count * 8 + lower * 4, as: UInt32.self))
            let value = Float(bitPattern: bits)
            return value.isFinite ? Double(value) : 0
        }
    }
}
