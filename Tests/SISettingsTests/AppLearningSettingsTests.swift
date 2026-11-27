import Foundation
import Testing
import SIStorage
@testable import SISettings

@MainActor
struct AppLearningSettingsTests {
    private final class Permission { var allowed = false }

    @Test func independentConsentRequiresAccessibilityAndDoesNotStartFromOtherFlags() async throws {
        let suite = "si-app-learning-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set(true, forKey: "inputHistory.enabled")
        defaults.set(true, forKey: "applicationMemory.enabled")
        defaults.set(true, forKey: "sentenceHistory.enabled")
        let permission = Permission()
        let settings = AppLearningSettings(defaults: defaults, store: AppLearningStore(root: root), checkPermission: { permission.allowed })
        #expect(!settings.enabled && !settings.canSample)
        var changed = 0
        settings.onConfigurationChanged = { changed += 1 }
        settings.enabled = true
        #expect(settings.enabled && !settings.canSample && !settings.permissionGranted)
        #expect(defaults.bool(forKey: "appLearning.enabled"))
        permission.allowed = true
        settings.refreshPermission()
        #expect(settings.canSample)
        settings.failed()
        #expect(!settings.canSample && settings.errorMessage != nil)
        settings.retry()
        #expect(settings.canSample)
        settings.enabled = false
        #expect(!settings.canSample)
        #expect(changed == 3)
        #expect(defaults.bool(forKey: "inputHistory.enabled") && defaults.bool(forKey: "applicationMemory.enabled"))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func clearInvalidatesPendingWorkWithoutChangingConsent() async throws {
        let suite = "si-app-clear-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppLearningStore(root: root)
        let settings = AppLearningSettings(defaults: defaults, store: store, checkPermission: { true })
        settings.enabled = true
        let generation = settings.generation
        let storage = await store.generation()
        await settings.clear()
        #expect(settings.enabled && settings.canSample)
        #expect(settings.generation > generation)
        do {
            _ = try await store.observe(bundle: "org.example.synthetic", paragraphs: ["你好世界"], expectedGeneration: storage)
            Issue.record("An obsolete snapshot must not recreate cleared app data")
        } catch {}
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
