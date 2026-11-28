import Foundation

/// Activity timing only. No input events, key identities or pointer positions are retained.
struct AppLearningActivityGate {
    static let pollInterval: Duration = .seconds(10)
    static let cooldown: Duration = .seconds(30)
    private var lastCheck: ContinuousClock.Instant

    init(now: ContinuousClock.Instant) { lastCheck = now }

    /// Only activity since the preceding check and after the cooldown can trigger a sample.
    /// Polling delays use their actual elapsed time; activity inside the cooldown is discarded.
    mutating func shouldSample(at now: ContinuousClock.Instant, idleSeconds: Double,
                               lastSampleStarted: ContinuousClock.Instant?) -> Bool {
        defer { lastCheck = now }
        guard idleSeconds.isFinite, idleSeconds >= 0 else { return false }
        let eligibleFrom = lastSampleStarted.map { max(lastCheck, $0.advanced(by: Self.cooldown)) } ?? lastCheck
        guard now >= eligibleFrom else { return false }
        let elapsed = eligibleFrom.duration(to: now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return idleSeconds <= seconds
    }
}
