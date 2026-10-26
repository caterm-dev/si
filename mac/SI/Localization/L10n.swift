import Foundation

/// UI resources follow macOS language preferences independently of enabled input languages.
public enum L10n {
    public static let bundle: Bundle = {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }()

    public static func text(_ key: String, bundle: Bundle = L10n.bundle) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    public static func format(_ key: String, _ arguments: CVarArg..., bundle: Bundle = L10n.bundle) -> String {
        String(format: text(key, bundle: bundle), locale: Locale.current, arguments: arguments)
    }
}
