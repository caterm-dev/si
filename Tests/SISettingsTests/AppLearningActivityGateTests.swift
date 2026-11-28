import Foundation
import Testing
@testable import SISettings

struct AppLearningActivityGateTests {
    @Test func idleComputerNeverSamplesAndTheFirstNewActivityDoesNotWaitThirtySeconds() {
        let start = ContinuousClock.now
        var gate = AppLearningActivityGate(now: start)
        for second in stride(from: 10, through: 60, by: 10) {
            let idleAllowed = gate.shouldSample(at: start.advanced(by: .seconds(second)), idleSeconds: Double(second + 10), lastSampleStarted: nil)
            #expect(!idleAllowed)
        }
        let newActivity = gate.shouldSample(at: start.advanced(by: .seconds(70)), idleSeconds: 8, lastSampleStarted: nil)
        #expect(newActivity)
    }

    @Test func continuousActivityIsLimitedToOneSamplePerThirtySeconds() {
        let start = ContinuousClock.now
        var gate = AppLearningActivityGate(now: start)
        var lastSample: ContinuousClock.Instant?
        var samples: [Int] = []
        for second in stride(from: 10, through: 100, by: 10) {
            let now = start.advanced(by: .seconds(second))
            if gate.shouldSample(at: now, idleSeconds: 0, lastSampleStarted: lastSample) {
                lastSample = now
                samples.append(second)
            }
        }
        #expect(samples == [10, 40, 70, 100])
    }

    @Test func activityInsideCooldownIsNotQueuedAndIdleTicksDoNotStartAnotherSample() {
        let start = ContinuousClock.now
        var gate = AppLearningActivityGate(now: start)
        let sampled = start.advanced(by: .seconds(1))
        let initialActivity = gate.shouldSample(at: sampled, idleSeconds: 0.1, lastSampleStarted: nil)
        #expect(initialActivity)
        // Input at second 25, then none through and beyond the cooldown boundary.
        let cooldownActivity = gate.shouldSample(at: start.advanced(by: .seconds(25)), idleSeconds: 0, lastSampleStarted: sampled)
        #expect(!cooldownActivity)
        let expiredButIdle = gate.shouldSample(at: start.advanced(by: .seconds(31)), idleSeconds: 6, lastSampleStarted: sampled)
        #expect(!expiredButIdle)
        let stillIdle = gate.shouldSample(at: start.advanced(by: .seconds(90)), idleSeconds: 65, lastSampleStarted: sampled)
        #expect(!stillIdle)
        let resumedActivity = gate.shouldSample(at: start.advanced(by: .seconds(91)), idleSeconds: 0.5, lastSampleStarted: sampled)
        #expect(resumedActivity)
    }

    @Test func delayedPollingStillDetectsFreshActivityAndIneligibleAttemptsDoNotConsumeCooldown() {
        let start = ContinuousClock.now
        var gate = AppLearningActivityGate(now: start)
        let delayedActivity = gate.shouldSample(at: start.advanced(by: .seconds(2.5)), idleSeconds: 2, lastSampleStarted: nil)
        #expect(delayedActivity)
        // An ineligible app did not start a capture, so new activity can immediately retry.
        let nextActivity = gate.shouldSample(at: start.advanced(by: .seconds(3.5)), idleSeconds: 0.4, lastSampleStarted: nil)
        #expect(nextActivity)
        let idleAfterward = gate.shouldSample(at: start.advanced(by: .seconds(10)), idleSeconds: 7, lastSampleStarted: nil)
        #expect(!idleAfterward)
    }

    @Test func restartingDoesNotBypassCooldownOrReplayActivityBeforeRestart() {
        let start = ContinuousClock.now
        var gate = AppLearningActivityGate(now: start.advanced(by: .seconds(10)))
        let stillCooling = gate.shouldSample(at: start.advanced(by: .seconds(11)), idleSeconds: 0, lastSampleStarted: start)
        #expect(!stillCooling)
        let oldCooldownActivity = gate.shouldSample(at: start.advanced(by: .seconds(31)), idleSeconds: 2, lastSampleStarted: start)
        #expect(!oldCooldownActivity)
        let freshActivity = gate.shouldSample(at: start.advanced(by: .seconds(32)), idleSeconds: 0.1, lastSampleStarted: start)
        #expect(freshActivity)
        var restarted = AppLearningActivityGate(now: start.advanced(by: .seconds(100)))
        let preRestartActivity = restarted.shouldSample(at: start.advanced(by: .seconds(101)), idleSeconds: 2, lastSampleStarted: start)
        #expect(!preRestartActivity)
    }

    @Test func invalidOrUnavailableIdleTimeFailsClosed() {
        let start = ContinuousClock.now
        var gate = AppLearningActivityGate(now: start)
        for (offset, idle) in [Double.nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude].enumerated() {
            let invalidActivity = gate.shouldSample(at: start.advanced(by: .seconds(offset + 1)), idleSeconds: idle, lastSampleStarted: nil)
            #expect(!invalidActivity)
        }
        let recoveredActivity = gate.shouldSample(at: start.advanced(by: .seconds(6)), idleSeconds: 0, lastSampleStarted: nil)
        #expect(recoveredActivity)
    }
}
