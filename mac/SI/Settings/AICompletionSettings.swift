import Foundation
import LocalAuthentication
import Observation
import Security

@MainActor
@Observable
final class AICompletionSettings {
    static let shared = AICompletionSettings()

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "aiCompletion.enabled")
            defaults.set(enabled, forKey: "aiCompletion.screenshotConsent")
            generation &+= 1
        }
    }
    var provider: AICompletionProvider {
        didSet {
            guard provider != oldValue else { return }
            enabled = false
            resolvedCLIPath = nil
            cliLookupGeneration &+= 1
            defaults.set(provider.rawValue, forKey: "aiCompletion.provider")
        }
    }
    private(set) var hasAPIKey = false
    private(set) var generation: UInt64 = 0
    private(set) var error: String?
    private var cliPaths: [String: String]
    private(set) var resolvedCLIPath: String?
    @ObservationIgnored private var cliLookupGeneration: UInt64 = 0
    private let defaults = SettingsDefaults.shared

    private init() {
        // Screenshot consent has a different scope from the retired automatic AX feature.
        let screenshotEnabled = defaults.bool(forKey: "aiCompletion.screenshotConsent") && defaults.bool(forKey: "aiCompletion.enabled")
        enabled = screenshotEnabled
        defaults.set(screenshotEnabled, forKey: "aiCompletion.enabled")
        defaults.removeObject(forKey: "aiCompletion.applications")
        provider = AICompletionProvider(rawValue: defaults.string(forKey: "aiCompletion.provider") ?? "") ?? .codex
        cliPaths = defaults.dictionary(forKey: "aiCompletion.cliPaths") as? [String: String] ?? [:]
    }

    var cliPath: String? { cliPaths[provider.rawValue] }

    func refreshCLIPath() async {
        cliLookupGeneration &+= 1
        let lookup = cliLookupGeneration
        let selected = provider
        let path = cliPath
        let resolved = await AICompletionExecutable.resolve(provider: selected, configuredPath: path)
        guard lookup == cliLookupGeneration, provider == selected, cliPath == path else { return }
        resolvedCLIPath = resolved
    }

    @discardableResult
    func setCLIPath(_ value: String?) async -> Bool {
        cliLookupGeneration &+= 1
        let lookup = cliLookupGeneration
        let selected = provider
        let path = value.map { AICompletionExecutable.normalizedPath($0) }
        let resolved = await AICompletionExecutable.resolve(provider: selected, configuredPath: path)
        guard lookup == cliLookupGeneration, provider == selected else { return false }
        guard path == nil || resolved != nil else {
            error = "Enter an absolute path to an executable file."
            return false
        }
        cliPaths[selected.rawValue] = path
        defaults.set(cliPaths, forKey: "aiCompletion.cliPaths")
        resolvedCLIPath = resolved
        enabled = false
        error = nil
        return true
    }

    func refreshCredentialStatus() async {
        hasAPIKey = await AICompletionCredentials.shared.read() != nil
    }

    func saveAPIKey(_ value: String?) async {
        enabled = false
        let saved = await AICompletionCredentials.shared.save(value)
        if saved { hasAPIKey = value != nil }
        error = saved ? nil : "Could not update the OpenAI API key in Keychain."
    }

    func reportFailure(_ message: String?) {
        error = message
    }
}

actor AICompletionCredentials {
    static let shared = AICompletionCredentials()

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.caterm.inputmethod.si.aiCompletion",
         kSecAttrAccount as String: "OpenAI API"]
    }

    func read() -> String? {
        var request = query
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String?) -> Bool {
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let changes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var attributes = query
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
