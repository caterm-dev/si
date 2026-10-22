import Foundation

/// Shared app/package resource lookup. Called on candidate workers during lazy initialization.
enum DictionaryResources {
    static func url(_ name: String, extension suffix: String, languageDirectory: String) -> URL? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        return bundle.url(forResource: name, withExtension: suffix, subdirectory: languageDirectory)
            ?? bundle.url(forResource: name, withExtension: suffix, subdirectory: "Resources/\(languageDirectory)")
            ?? bundle.url(forResource: name, withExtension: suffix)
    }
}
