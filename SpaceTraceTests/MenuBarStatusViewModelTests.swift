import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import Testing
@testable import SpaceTrace

@MainActor
struct MenuBarStatusViewModelTests {
    @Test("Local qualification diagnostics are visible only while enabled")
    func exposesQualificationIndicator() {
        let model = MenuBarStatusViewModel()

        #expect(model.qualificationDiagnosticsActive == false)
        model.setQualificationDiagnosticsActive(true)
        #expect(model.qualificationDiagnosticsActive)
        model.handleCompositionFailure()
        #expect(model.qualificationDiagnosticsActive == false)
    }

    @Test("A qualified query becomes the menu bar's current 24-hour evidence")
    func refreshesQualifiedEvidence() async throws {
        let end = Date(timeIntervalSince1970: 1_900_000_000)
        let status = StartupVolume24HourStatus(
            qualification: .qualified,
            currentAvailableBytes: try ByteCount(8_000),
            currentObservedAt: end,
            baselineObservedAt: end.addingTimeInterval(-86_400),
            change: .volumeAvailable(bytes: -2_000)
        )
        let loader = MenuStatusLoaderFake(result: .success(status))
        let model = MenuBarStatusViewModel(loader: loader, now: { end })

        await model.refresh()

        #expect(model.storageState == .loaded(status))
        #expect(await loader.requestedEnds == [end])
    }

    @Test("A failed refresh never preserves a previous value as current")
    func replacesPreviousEvidenceWithFailure() async throws {
        let end = Date(timeIntervalSince1970: 1_900_000_000)
        let status = StartupVolume24HourStatus(
            qualification: .collecting,
            currentAvailableBytes: try ByteCount(8_000),
            currentObservedAt: end,
            baselineObservedAt: nil,
            change: nil
        )
        let loader = MenuStatusLoaderFake(
            results: [.success(status), .failure]
        )
        let model = MenuBarStatusViewModel(loader: loader, now: { end })

        await model.refresh()
        #expect(model.storageState == .loaded(status))
        await model.refresh()

        #expect(model.storageState == .failed)
    }

    @Test("A successful lifecycle sample refreshes the menu bar projection")
    func observesBackgroundSampling() async throws {
        let end = Date(timeIntervalSince1970: 1_900_000_000)
        let status = StartupVolume24HourStatus(
            qualification: .collecting,
            currentAvailableBytes: try ByteCount(8_000),
            currentObservedAt: end,
            baselineObservedAt: nil,
            change: nil
        )
        let loader = MenuStatusLoaderFake(result: .success(status))
        let background = MenuBackgroundObserverFake()
        let model = MenuBarStatusViewModel(loader: loader, now: { end })
        let monitorTask = Task {
            await model.monitor(background: background)
        }

        await background.emit(
            StorageHistoryBackgroundState(
                phase: .awake,
                processedEventCount: 1,
                lastSampleTrigger: .startup,
                lastSampleAttemptAt: end,
                lastSuccessfulSampleAt: end,
                sampleFailureCount: 0,
                consecutiveSampleFailureCount: 0,
                lastRetentionAttemptAt: nil,
                lastSuccessfulRetentionAt: nil,
                retentionFailureCount: 0
            )
        )
        for _ in 0..<100 {
            if model.storageState == .loaded(status) { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        await background.finish()
        await monitorTask.value

        #expect(model.storageState == .loaded(status))
        #expect(model.backgroundState.lastSuccessfulSampleAt == end)
    }

    @Test("Operational presentation preserves scan and evidence priority")
    func resolvesOperationalPriority() throws {
        let status = StartupVolume24HourStatus(
            qualification: .qualified,
            currentAvailableBytes: try ByteCount(8_000),
            currentObservedAt: Date(),
            baselineObservedAt: Date().addingTimeInterval(-86_400),
            change: .volumeAvailable(bytes: -2_000)
        )
        let storage = MenuBarStorageState.loaded(status)

        #expect(
            MenuBarOperationalState.resolve(
                storage: storage,
                authorization: .ready(authorizedCount: 1),
                baseline: .idle,
                recoveryIsActive: false
            ) == .healthy
        )
        #expect(
            MenuBarOperationalState.resolve(
                storage: storage,
                authorization: .needsAttention(
                    authorizedCount: 1,
                    issueCount: 1
                ),
                baseline: .idle,
                recoveryIsActive: false
            ) == .attentionRequired
        )
        #expect(
            MenuBarOperationalState.resolve(
                storage: storage,
                authorization: .ready(authorizedCount: 1),
                baseline: .preparing(
                    request: try AuthorizedBaselineScanRequest(
                        scopeIDs: [WatchedScopeID("menu-test")]
                    ),
                    startedAt: Date()
                ),
                recoveryIsActive: false
            ) == .scanning
        )
        #expect(
            MenuBarOperationalState.resolve(
                storage: storage,
                authorization: .ready(authorizedCount: 1),
                baseline: .idle,
                recoveryIsActive: true
            ) == .unavailable
        )
    }
}

private actor MenuStatusLoaderFake: StartupVolume24HourStatusLoading {
    enum Result: Sendable {
        case success(StartupVolume24HourStatus)
        case failure
    }

    private var results: [Result]
    private(set) var requestedEnds: [Date] = []

    init(result: Result) {
        results = [result]
    }

    init(results: [Result]) {
        self.results = results
    }

    func load(through end: Date) throws -> StartupVolume24HourStatus {
        requestedEnds.append(end)
        guard results.isEmpty == false else {
            throw MenuStatusLoaderError.missingFixture
        }
        switch results.removeFirst() {
        case let .success(status):
            return status
        case .failure:
            throw MenuStatusLoaderError.queryFailed
        }
    }
}

private enum MenuStatusLoaderError: Error {
    case missingFixture
    case queryFailed
}

private actor MenuBackgroundObserverFake:
    StorageHistoryBackgroundStateObserving
{
    private let stream: AsyncStream<StorageHistoryBackgroundState>
    private let continuation: AsyncStream<
        StorageHistoryBackgroundState
    >.Continuation

    init() {
        let pair = AsyncStream<StorageHistoryBackgroundState>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func updates() -> AsyncStream<StorageHistoryBackgroundState> {
        stream
    }

    func emit(_ state: StorageHistoryBackgroundState) {
        continuation.yield(state)
    }

    func finish() {
        continuation.finish()
    }
}
