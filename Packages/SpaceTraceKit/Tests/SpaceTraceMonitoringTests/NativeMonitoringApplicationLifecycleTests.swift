import SpaceTraceApplication
import Testing
@testable import SpaceTraceMonitoring

struct NativeMonitoringApplicationLifecycleTests {
    @Test("An empty bookmark catalog leaves native monitoring idle")
    func staysIdleWithoutConfiguredScopes() async throws {
        let report = WatchedScopeRestorationReport(
            configuredScopeCount: 0,
            scopes: [],
            failures: []
        )
        let catalog = RestorableCatalogFake(report: report)
        let runtime = VolumeMonitoringRuntimeFake()
        let lifecycle = NativeMonitoringApplicationLifecycle(
            catalog: catalog,
            runtime: runtime
        )

        let restored = try await lifecycle.start()

        #expect(restored == report)
        #expect(await lifecycle.state() == .idleWithoutConfiguredScopes)
        #expect(await runtime.hasStarted == false)
        await lifecycle.stop()
        #expect(await catalog.releaseCount == 1)
    }

    @Test("A configured but unavailable external scope still starts mount observation")
    func startsForUnavailableConfiguredScope() async throws {
        let scopeID = try WatchedScopeID("scope-external")
        let report = WatchedScopeRestorationReport(
            configuredScopeCount: 1,
            scopes: [],
            failures: [
                WatchedScopeRestorationFailure(
                    scopeID: scopeID,
                    code: .resourceUnavailable
                ),
            ]
        )
        let catalog = RestorableCatalogFake(report: report)
        let runtime = VolumeMonitoringRuntimeFake()
        let lifecycle = NativeMonitoringApplicationLifecycle(
            catalog: catalog,
            runtime: runtime
        )

        _ = try await lifecycle.start()
        await runtime.waitUntilStarted()

        #expect(await lifecycle.state() == .monitoring)
        await lifecycle.stop()
        #expect(await runtime.wasCancelled)
        #expect(await catalog.releaseCount == 1)
        #expect(await lifecycle.state() == .stopped)
    }

    @Test("Application startup resumes and shutdown cancels historical projection")
    func ownsHistoricalProjectionLifecycle() async throws {
        let scope = try WatchedScope(
            id: WatchedScopeID("scope-primary"),
            root: DirtyRegionPath("/Volumes/Test/Selected"),
            mountPath: DirtyRegionPath("/Volumes/Test")
        )
        let catalog = RestorableCatalogFake(
            report: WatchedScopeRestorationReport(
                configuredScopeCount: 1,
                scopes: [scope],
                failures: []
            )
        )
        let runtime = VolumeMonitoringRuntimeFake()
        let projector = HistoricalFindingProjectingFake()
        let lifecycle = NativeMonitoringApplicationLifecycle(
            catalog: catalog,
            runtime: runtime,
            historicalFindingProjector: projector
        )

        _ = try await lifecycle.start()
        await projector.waitUntilStarted()
        #expect(await projector.receivedLimits == [100])

        await lifecycle.stop()
        #expect(await projector.wasCancelled)
    }

    @Test("The application lifecycle rejects duplicate monitoring tasks")
    func rejectsDuplicateStart() async throws {
        let scope = try WatchedScope(
            id: WatchedScopeID("scope-primary"),
            root: DirtyRegionPath("/Volumes/Test/Selected"),
            mountPath: DirtyRegionPath("/Volumes/Test")
        )
        let catalog = RestorableCatalogFake(
            report: WatchedScopeRestorationReport(
                configuredScopeCount: 1,
                scopes: [scope],
                failures: []
            )
        )
        let runtime = VolumeMonitoringRuntimeFake()
        let lifecycle = NativeMonitoringApplicationLifecycle(
            catalog: catalog,
            runtime: runtime
        )
        _ = try await lifecycle.start()
        await runtime.waitUntilStarted()

        await #expect(throws: NativeMonitoringApplicationLifecycleError.alreadyStarted) {
            _ = try await lifecycle.start()
        }

        await lifecycle.stop()
    }

    @Test("A catalog persistence failure releases permission state and fails startup")
    func failsClosedWhenRestorationFails() async {
        let catalog = FailingRestorableCatalogFake()
        let runtime = VolumeMonitoringRuntimeFake()
        let lifecycle = NativeMonitoringApplicationLifecycle(
            catalog: catalog,
            runtime: runtime
        )

        await #expect(throws: LifecycleFixtureError.restoreFailed) {
            _ = try await lifecycle.start()
        }

        #expect(await lifecycle.state() == .failed)
        #expect(await catalog.releaseCount == 1)
        #expect(await runtime.hasStarted == false)
    }
}

private actor RestorableCatalogFake: RestorableWatchedScopeCatalog {
    let report: WatchedScopeRestorationReport
    private(set) var releaseCount = 0

    init(report: WatchedScopeRestorationReport) {
        self.report = report
    }

    func restore() -> WatchedScopeRestorationReport {
        report
    }

    func watchedScopes() -> [WatchedScope] {
        report.scopes
    }

    func releaseAll() {
        releaseCount += 1
    }
}

private actor VolumeMonitoringRuntimeFake: VolumeMonitoringRuntime {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var hasStarted = false
    private(set) var wasCancelled = false

    func run() async throws {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor FailingRestorableCatalogFake: RestorableWatchedScopeCatalog {
    private(set) var releaseCount = 0

    func restore() throws -> WatchedScopeRestorationReport {
        throw LifecycleFixtureError.restoreFailed
    }

    func watchedScopes() -> [WatchedScope] {
        []
    }

    func releaseAll() {
        releaseCount += 1
    }
}

private actor HistoricalFindingProjectingFake: HistoricalFindingProjecting {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var receivedLimits: [Int] = []
    private(set) var wasCancelled = false

    func projectPending(limit: Int) async throws -> HistoricalFindingProjectionRun {
        receivedLimits.append(limit)
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
        return .empty
    }

    func waitUntilStarted() async {
        if receivedLimits.isEmpty == false { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private enum LifecycleFixtureError: Error {
    case restoreFailed
}
