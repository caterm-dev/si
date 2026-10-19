import Foundation

@MainActor
enum SettingsDefaults {
    // Keep preferences and learning consent in the original domain across the bundle-ID correction.
    static let shared = UserDefaults(suiteName: "com.caterm.si") ?? .standard
}
