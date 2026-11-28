import AppKit
import ApplicationServices
import Carbon

@MainActor
final class AppLearningSampler {
    static let shared = AppLearningSampler()
    private let settings = AppLearningSettings.shared
    private var timer: Task<Void, Never>?
    private var stopping = false
    private var lastSampleStarted: ContinuousClock.Instant?

    func start() {
        settings.onConfigurationChanged = { [weak self] in self?.restart() }
        Task { await settings.load() }
        restart()
    }

    private func restart() {
        let previous = timer
        previous?.cancel()
        let generation = settings.generation
        let reset = !settings.enabled
        timer = Task {
            await previous?.value
            if reset { await settings.store.resetSessions() }
            guard !Task.isCancelled, !stopping else { return }
            guard settings.enabled else { return }
            var activity = AppLearningActivityGate(now: .now)
            while !Task.isCancelled, !stopping, settings.enabled, settings.generation == generation {
                do { try await Task.sleep(for: AppLearningActivityGate.pollInterval) } catch { return }
                guard !Task.isCancelled, !stopping, settings.enabled, settings.generation == generation else { return }
                // kCGAnyInputEventType includes keyboard, mouse movement/dragging and scrolling.
                // Read only HID idle time; no event tap, event payload or monitoring permission.
                guard let anyInput = CGEventType(rawValue: UInt32.max) else { return }
                let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
                if activity.shouldSample(at: .now, idleSeconds: idle, lastSampleStarted: lastSampleStarted) {
                    await sample(generation: generation)
                }
            }
        }
    }

    private func sample(generation: UInt64) async {
        settings.refreshPermission()
        let context = AppLearningContext.shared
        guard settings.canSample, !Task.isCancelled, context.hasClient,
              let bundle = context.bundle, !LanguageSettings.shared.usesPassthrough(in: bundle),
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundle,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !IsSecureEventInputEnabled(),
              let window = AICompletionScreenshot.frontWindow(pid: app.processIdentifier) else { return }
        let epoch = context.generation
        let languageGeneration = LanguageSettings.shared.configurationGeneration
        let pid = app.processIdentifier
        let launch = app.launchDate
        let valid: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return !self.stopping && self.settings.canSample && self.settings.generation == generation
                && AXIsProcessTrusted() && !IsSecureEventInputEnabled()
                && context.hasClient && context.generation == epoch && context.bundle == bundle
                && LanguageSettings.shared.configurationGeneration == languageGeneration
                && !LanguageSettings.shared.usesPassthrough(in: bundle)
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                && NSWorkspace.shared.frontmostApplication?.launchDate == launch
                && AICompletionScreenshot.frontWindow(pid: pid)?.id == window.id
        }
        settings.sampling(true)
        defer { settings.sampling(false) }
        do {
            let storageGeneration = await settings.store.generation()
            guard valid(), !Task.isCancelled else { return }
            // Start the global cooldown immediately before AX capture, after any storage wait.
            // Keep it across restarts so Retry/off-on cannot bypass the interval.
            lastSampleStarted = .now
            let snapshot = try await AppLearningCapture(pid: pid, validate: valid).capture()
            guard valid(), !Task.isCancelled else { return }
            let changed = try await settings.store.observe(bundle: bundle, paragraphs: snapshot.paragraphs,
                                                           expectedGeneration: storageGeneration)
            guard settings.generation == generation else { return }
            await settings.sampled(changed: changed)
        } catch is AppLearningCapture.Failure {
            if settings.generation == generation { settings.skipped() }
        } catch is CancellationError {
            return
        } catch {
            if settings.generation == generation { settings.failed() }
        }
    }

    func shutdown() async {
        stopping = true
        timer?.cancel()
        await timer?.value
        await settings.store.resetSessions()
    }
}
