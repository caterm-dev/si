import Foundation

/// A row from the current user.silex snapshot. Identity preserves exact UTF-8 bytes.
public struct UserLexiconEntry: Identifiable, Sendable, Equatable {
    public let text: String
    public let reading: String
    public let index: UInt32
    public let count: UInt64
    public var id: Data {
        var data = Data("\(index):".utf8)
        data.append(contentsOf: reading.utf8)
        data.append(0)
        data.append(contentsOf: text.utf8)
        return data
    }
    public init(text: String, reading: String, index: UInt32, count: UInt64) {
        self.text = text
        self.reading = reading
        self.index = index
        self.count = count
    }
}
