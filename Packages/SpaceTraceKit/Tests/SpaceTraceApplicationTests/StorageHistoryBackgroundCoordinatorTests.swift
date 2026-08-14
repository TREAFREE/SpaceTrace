import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import Testing

struct StorageHistoryBackgroundCoordinatorTests {
    @Test("Sleep pauses periodic writes and wake samples immediately")
    func sleepWakeLifecycle() async throws {
        let recorder = BackgroundRecorderFake()
        let retention = BackgroundRetentionFake()
        let coordinator = StorageHistoryBackgroundCoordinator(
            recorder: recorder,
            retention: retention
        )
        await coordinator.start()

        #expect(
            await coordinator.handle(.started(at: instant(hour: 0)))
                == .completed
        )
        #expect(
            await coordinator.handle(.willSleep(at: instant(hour: 1)))
                == .completed
        )
        #expect(
            await coordinator.handle(.periodic(at: instant(hour: 2)))
                == .deferredWhileSleeping
        )
        #expect(
            await coordinator.handle(.didWake(at: instant(hour: 3)))
                == .completed
        )

        #expect(await recorder.recordCount == 3)
        #expect(await recorder.triggers == [.startup, .sleep, .wake])
        let state = await coordinator.currentState
        #expect(state.phase == .awake)
        #expect(state.lastSuccessfulSampleAt == instant(hour: 3))
        await coordinator.stop()
    }

    @Test("Clock and timezone changes sample immediately without writing during sleep")
    func significantTimeChanges() async {
        let recorder = BackgroundRecorderFake()
        let coordinator = StorageHistoryBackgroundCoordinator(
            recorder: recorder,
            retention: BackgroundRetentionFake()
        )
        await coordinator.start()
        _ = await coordinator.handle(.started(at: instant(hour: 0)))
        _ = await coordinator.handle(.significantTimeChanged(at: instant(hour: 1)))
        _ = await coordinator.handle(.willSleep(at: instant(hour: 2)))

        #expect(
            await coordinator.handle(.significantTimeChanged(at: instant(hour: 3)))
                == .deferredWhileSleeping
        )
        _ = await coordinator.handle(.didWake(at: instant(hour: 4)))

        #expect(await recorder.recordCount == 4)
        #expect(
            await recorder.triggers
                == [.startup, .significantTimeChange, .sleep, .wake]
        )
        await coordinator.stop()
    }

    @Test("A failed sample remains visible and does not stop a later recovery")
    func samplingFailureRecovers() async {
        let recorder = BackgroundRecorderFake(failAttempts: [1])
        let coordinator = StorageHistoryBackgroundCoordinator(
            recorder: recorder,
            retention: BackgroundRetentionFake()
        )
        await coordinator.start()

        #expect(
            await coordinator.handle(.started(at: instant(hour: 0)))
                == .failed
        )
        #expect(
            await coordinator.handle(.periodic(at: instant(hour: 1)))
                == .completed
        )

        let state = await coordinator.currentState
        #expect(state.sampleFailureCount == 1)
        #expect(state.consecutiveSampleFailureCount == 0)
        #expect(state.lastSuccessfulSampleAt == instant(hour: 1))
        await coordinator.stop()
    }

    @Test("Retention reports deferral on failure and succeeds on the next scheduled run")
    func retentionRetries() async {
        let retention = BackgroundRetentionFake(failAttempts: [1])
        let coordinator = StorageHistoryBackgroundCoordinator(
            recorder: BackgroundRecorderFake(),
            retention: retention
        )
        await coordinator.start()

        #expect(
            await coordinator.handle(.maintenance(at: instant(hour: 24)))
                == .failed
        )
        #expect(
            await coordinator.handle(.maintenance(at: instant(hour: 48)))
                == .completed
        )

        let state = await coordinator.currentState
        #expect(state.retentionFailureCount == 1)
        #expect(state.lastSuccessfulRetentionAt == instant(hour: 48))
        await coordinator.stop()
    }

    @Test(
        "Thirty virtual days survive sleep, wake, and time changes with bounded serialized work",
        .timeLimit(.minutes(1))
    )
    func thirtyDayVirtualQualification() async {
        let recorder = BackgroundRecorderFake()
        let retention = BackgroundRetentionFake()
        let coordinator = StorageHistoryBackgroundCoordinator(
            recorder: recorder,
            retention: retention
        )
        await coordinator.start()
        _ = await coordinator.handle(.started(at: instant(hour: 0)))

        for hour in 1...720 {
            if hour == 200 {
                _ = await coordinator.handle(.willSleep(at: instant(hour: hour)))
            }
            if hour == 201 {
                _ = await coordinator.handle(.didWake(at: instant(hour: hour)))
            }
            _ = await coordinator.handle(.periodic(at: instant(hour: hour)))
            if hour == 400 {
                _ = await coordinator.handle(
                    .significantTimeChanged(at: instant(hour: hour))
                )
            }
            if hour.isMultiple(of: 24) {
                _ = await coordinator.handle(.maintenance(at: instant(hour: hour)))
            }
        }

        let state = await coordinator.currentState
        #expect(await recorder.recordCount == 723)
        #expect(await recorder.maximumConcurrentOperations == 1)
        #expect(await retention.applyCount == 30)
        #expect(await retention.maximumConcurrentOperations == 1)
        #expect(state.processedEventCount == 754)
        #expect(state.lastSuccessfulSampleAt == instant(hour: 720))
        #expect(state.lastSuccessfulRetentionAt == instant(hour: 720))
        await coordinator.stop()
        #expect(await coordinator.currentState.phase == .stopped)
    }
}

private actor BackgroundRecorderFake: StartupVolumeCapacityRecording {
    private let failAttempts: Set<Int>
    private(set) var recordCount = 0
    private(set) var triggers: [StorageHistorySampleTrigger] = []
    private var concurrentOperations = 0
    private(set) var maximumConcurrentOperations = 0

    init(failAttempts: Set<Int> = []) {
        self.failAttempts = failAttempts
    }

    func record(trigger: StorageHistorySampleTrigger) throws {
        recordCount += 1
        triggers.append(trigger)
        concurrentOperations += 1
        maximumConcurrentOperations = max(
            maximumConcurrentOperations,
            concurrentOperations
        )
        defer { concurrentOperations -= 1 }
        if failAttempts.contains(recordCount) {
            throw BackgroundFixtureError.injectedFailure
        }
    }
}

private actor BackgroundRetentionFake: StorageHistoryRetentionApplying {
    private let failAttempts: Set<Int>
    private(set) var applyCount = 0
    private var concurrentOperations = 0
    private(set) var maximumConcurrentOperations = 0

    init(failAttempts: Set<Int> = []) {
        self.failAttempts = failAttempts
    }

    func applyStorageHistoryRetention(referenceDate: Date) throws {
        _ = referenceDate
        applyCount += 1
        concurrentOperations += 1
        maximumConcurrentOperations = max(
            maximumConcurrentOperations,
            concurrentOperations
        )
        defer { concurrentOperations -= 1 }
        if failAttempts.contains(applyCount) {
            throw BackgroundFixtureError.injectedFailure
        }
    }
}

private enum BackgroundFixtureError: Error {
    case injectedFailure
}

private func instant(hour: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(hour) * 3_600)
}
