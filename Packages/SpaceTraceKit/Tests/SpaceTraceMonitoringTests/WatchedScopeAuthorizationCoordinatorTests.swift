import Foundation
import SpaceTraceApplication
import Testing
@testable import SpaceTraceMonitoring

struct WatchedScopeAuthorizationCoordinatorTests {
    @Test("Authorization restarts monitoring with the newly persisted grant")
    func authorizesAndRestarts() async throws {
        let catalog = MutableCatalogFake()
        let runtime = RestartableRuntimeFake()
        let lifecycle = NativeMonitoringApplicationLifecycle(
            catalog: catalog,
            runtime: runtime
        )
        let baseline = BaselineCancellationRecorder()
        let coordinator = WatchedScopeAuthorizationCoordinator(
            catalog: catalog,
            lifecycle: lifecycle,
            cancelBaselineScan: {
                await baseline.cancel()
            }
        )
        let scopeID = try WatchedScopeID("scope-primary")

        _ = try await coordinator.start()
        let report = try await coordinator.authorize(
            selectedURL: URL(fileURLWithPath: "/Volumes/Test/Selected", isDirectory: true),
            scopeID: scopeID
        )
        await runtime.waitForStartCount(1)

        #expect(report.configuredScopeCount == 1)
        #expect(report.scopes.map(\.id) == [scopeID])
        #expect(await catalog.acquiredScopeIDs == [scopeID])
        #expect(await baseline.cancelCount == 1)
        #expect(await lifecycle.state() == .monitoring)
        await coordinator.stop()
    }

    @Test("Revocation stops the old runtime and returns to an empty idle state")
    func revokesAndReturnsToIdle() async throws {
        let scopeID = try WatchedScopeID("scope-primary")
        let catalog = MutableCatalogFake(initialScopeID: scopeID)
        let runtime = RestartableRuntimeFake()
        let lifecycle = NativeMonitoringApplicationLifecycle(
            catalog: catalog,
            runtime: runtime
        )
        let coordinator = WatchedScopeAuthorizationCoordinator(
            catalog: catalog,
            lifecycle: lifecycle
        )

        _ = try await coordinator.start()
        await runtime.waitForStartCount(1)
        let report = try await coordinator.revoke(scopeID: scopeID)

        #expect(report.configuredScopeCount == 0)
        #expect(await catalog.removedScopeIDs == [scopeID])
        #expect(await runtime.cancelCount == 1)
        #expect(await lifecycle.state() == .idleWithoutConfiguredScopes)
        await coordinator.stop()
    }

    @Test("A failed mutation restores monitoring for the previous grant")
    func resumesAfterMutationFailure() async throws {
        let scopeID = try WatchedScopeID("scope-primary")
        let catalog = MutableCatalogFake(initialScopeID: scopeID, failAcquisition: true)
        let runtime = RestartableRuntimeFake()
        let lifecycle = NativeMonitoringApplicationLifecycle(
            catalog: catalog,
            runtime: runtime
        )
        let coordinator = WatchedScopeAuthorizationCoordinator(
            catalog: catalog,
            lifecycle: lifecycle
        )
        _ = try await coordinator.start()
        await runtime.waitForStartCount(1)

        await #expect(throws: AuthorizationFixtureError.acquisitionFailed) {
            _ = try await coordinator.authorize(
                selectedURL: URL(fileURLWithPath: "/Volumes/Test/Replacement", isDirectory: true),
                scopeID: scopeID
            )
        }
        await runtime.waitForStartCount(2)

        #expect(await lifecycle.state() == .monitoring)
        #expect(await runtime.cancelCount == 1)
        await coordinator.stop()
    }

    @Test("Application stop invalidates an in-flight authorization before runtime restart")
    func stopCancelsInFlightAuthorization() async throws {
        let catalog = BlockingMutableCatalogFake()
        let runtime = RestartableRuntimeFake()
        let lifecycle = NativeMonitoringApplicationLifecycle(
            catalog: catalog,
            runtime: runtime
        )
        let coordinator = WatchedScopeAuthorizationCoordinator(
            catalog: catalog,
            lifecycle: lifecycle
        )
        let scopeID = try WatchedScopeID("scope-primary")
        let authorizationTask = Task {
            try await coordinator.authorize(
                selectedURL: URL(fileURLWithPath: "/Volumes/Test/Selected", isDirectory: true),
                scopeID: scopeID
            )
        }
        await catalog.waitUntilAcquisitionStarts()

        await coordinator.stop()
        await catalog.resumeAcquisition()

        await #expect(
            throws: WatchedScopeAuthorizationCoordinatorError.transitionCancelled
        ) {
            _ = try await authorizationTask.value
        }
        #expect(await runtime.startCount == 0)
        #expect(await lifecycle.state() == .stopped)
    }
}

private actor BaselineCancellationRecorder {
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

private actor MutableCatalogFake: MutableWatchedScopeCatalog {
    private var scopes: [WatchedScopeID: WatchedScope] = [:]
    private let failAcquisition: Bool
    private(set) var acquiredScopeIDs: [WatchedScopeID] = []
    private(set) var removedScopeIDs: [WatchedScopeID] = []

    init(
        initialScopeID: WatchedScopeID? = nil,
        failAcquisition: Bool = false
    ) {
        self.failAcquisition = failAcquisition
        if let initialScopeID {
            scopes[initialScopeID] = try? WatchedScope(
                id: initialScopeID,
                root: DirtyRegionPath("/Volumes/Test/Selected"),
                mountPath: DirtyRegionPath("/Volumes/Test")
            )
        }
    }

    func acquire(selectedURL: URL, scopeID: WatchedScopeID) throws -> WatchedScope {
        if failAcquisition {
            throw AuthorizationFixtureError.acquisitionFailed
        }
        let scope = try WatchedScope(
            id: scopeID,
            root: DirtyRegionPath(selectedURL.standardizedFileURL.path),
            mountPath: DirtyRegionPath("/")
        )
        scopes[scopeID] = scope
        acquiredScopeIDs.append(scopeID)
        return scope
    }

    func remove(scopeID: WatchedScopeID) {
        scopes.removeValue(forKey: scopeID)
        removedScopeIDs.append(scopeID)
    }

    func restore() -> WatchedScopeRestorationReport {
        restorationReport()
    }

    func watchedScopes() -> [WatchedScope] {
        scopes.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    func restorationReport() -> WatchedScopeRestorationReport {
        WatchedScopeRestorationReport(
            configuredScopeCount: scopes.count,
            scopes: Array(scopes.values),
            failures: []
        )
    }

    func releaseAll() {}
}

private actor RestartableRuntimeFake: VolumeMonitoringRuntime {
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    func run() async throws {
        startCount += 1
        resumeSatisfiedWaiters()
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch is CancellationError {
            cancelCount += 1
            throw CancellationError()
        }
    }

    func waitForStartCount(_ expectedCount: Int) async {
        if startCount >= expectedCount { return }
        await withCheckedContinuation { continuation in
            waiters.append((expectedCount, continuation))
        }
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = waiters.filter { startCount >= $0.count }
        waiters.removeAll { startCount >= $0.count }
        satisfied.forEach { $0.continuation.resume() }
    }
}

private actor BlockingMutableCatalogFake: MutableWatchedScopeCatalog {
    private var scope: WatchedScope?
    private var acquisitionContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var acquisitionStarted = false

    func acquire(selectedURL: URL, scopeID: WatchedScopeID) async throws -> WatchedScope {
        acquisitionStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            acquisitionContinuation = continuation
        }
        let acquired = try WatchedScope(
            id: scopeID,
            root: DirtyRegionPath(selectedURL.standardizedFileURL.path),
            mountPath: DirtyRegionPath("/")
        )
        scope = acquired
        return acquired
    }

    func remove(scopeID: WatchedScopeID) {
        if scope?.id == scopeID {
            scope = nil
        }
    }

    func restore() -> WatchedScopeRestorationReport {
        restorationReport()
    }

    func watchedScopes() -> [WatchedScope] {
        scope.map { [$0] } ?? []
    }

    func restorationReport() -> WatchedScopeRestorationReport {
        WatchedScopeRestorationReport(
            configuredScopeCount: scope == nil ? 0 : 1,
            scopes: scope.map { [$0] } ?? [],
            failures: []
        )
    }

    func releaseAll() {}

    func waitUntilAcquisitionStarts() async {
        if acquisitionStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeAcquisition() {
        acquisitionContinuation?.resume()
        acquisitionContinuation = nil
    }
}

private enum AuthorizationFixtureError: Error {
    case acquisitionFailed
}
