import Foundation

/// Resource lookup for the offline comparison decoder.
enum DictionaryResources {
    static func url(_ name: String, extension suffix: String, languageDirectory: String) -> URL? {
        let root = ProcessInfo.processInfo.environment["SI_LEGACY_DICTIONARY_DIRECTORY"] ?? ".build/legacy-dictionaries"
        let url = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(languageDirectory, isDirectory: true)
            .appendingPathComponent("\(name).\(suffix)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
