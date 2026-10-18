public enum InputLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "Chinese (Simplified)"
        }
    }
}
