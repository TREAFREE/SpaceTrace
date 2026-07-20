import Foundation
import Observation
import SpaceTraceApplication
import SpaceTraceMonitoring

protocol WatchedScopeAuthorizationCoordinating: Sendable {
    func start() async throws -> WatchedScopeRestorationReport
    func refresh() async throws -> WatchedScopeRestorationReport
    func authorize(
        selectedURL: URL,
        scopeID: WatchedScopeID
    ) async throws -> WatchedScopeRestorationReport
    func revoke(scopeID: WatchedScopeID) async throws -> WatchedScopeRestorationReport
}

extension WatchedScopeAuthorizationCoordinator: WatchedScopeAuthorizationCoordinating {}

@MainActor
@Observable
final class DirectoryAuthorizationViewModel {
    private let picker: any DirectorySelecting
    private let makeScopeID: () throws -> WatchedScopeID
    private var coordinator: (any WatchedScopeAuthorizationCoordinating)?

    private(set) var summary: DirectoryAuthorizationSummary
    private(set) var items: [DirectoryAuthorizationItem] = []
    private(set) var operationError: DirectoryAuthorizationOperationError?
    private(set) var isBusy = false

    var authorizedScopeIDs: [WatchedScopeID] {
        items.filter(\.isAuthorized).map(\.id)
    }

    var hasUnavailableScope: Bool {
        items.contains { item in
            if case .unavailable = item.status { return true }
            return false
        }
    }

    var canAddDirectory: Bool {
        switch summary {
        case .unconfigured, .ready, .needsAttention:
            items.count < AuthorizedBaselineScanRequest.maximumScopeCount
        case .loading, .failed:
            false
        }
    }

    init(
        picker: (any DirectorySelecting)? = nil,
        coordinator: (any WatchedScopeAuthorizationCoordinating)? = nil,
        initialSummary: DirectoryAuthorizationSummary = .loading,
        makeScopeID: @escaping () throws -> WatchedScopeID = {
            try WatchedScopeID("user-selected-\(UUID().uuidString.lowercased())")
        }
    ) {
        self.picker = picker ?? SystemDirectoryPicker()
        self.coordinator = coordinator
        self.summary = initialSummary
        self.makeScopeID = makeScopeID
    }

    func connect(_ coordinator: any WatchedScopeAuthorizationCoordinating) {
        self.coordinator = coordinator
    }

    func start() async {
        guard let coordinator else {
            summary = .failed
            return
        }
        guard isBusy == false else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }
        do {
            apply(try await coordinator.start())
        } catch is CancellationError {
            return
        } catch {
            items = []
            summary = .failed
        }
    }

    func addDirectory() async {
        guard isBusy == false, let coordinator else { return }
        guard canAddDirectory else {
            operationError = .scopeLimitReached
            return
        }
        guard let selectedURL = await picker.selectDirectory() else { return }
        defer { selectedURL.stopAccessingSecurityScopedResource() }

        let scopeID: WatchedScopeID
        do {
            scopeID = try makeScopeID()
            guard items.contains(where: { $0.id == scopeID }) == false else {
                operationError = .scopeIdentityUnavailable
                return
            }
        } catch {
            operationError = .scopeIdentityUnavailable
            return
        }

        await perform(operationError: .authorizationFailed) {
            try await coordinator.authorize(selectedURL: selectedURL, scopeID: scopeID)
        }
    }

    func reauthorize(scopeID: WatchedScopeID) async {
        guard isBusy == false,
              items.contains(where: { $0.id == scopeID }),
              let coordinator,
              let selectedURL = await picker.selectDirectory() else { return }
        defer { selectedURL.stopAccessingSecurityScopedResource() }

        await perform(operationError: .authorizationFailed) {
            try await coordinator.authorize(selectedURL: selectedURL, scopeID: scopeID)
        }
    }

    func revoke(scopeID: WatchedScopeID) async {
        guard let coordinator,
              items.contains(where: { $0.id == scopeID }) else { return }
        await perform(operationError: .revocationFailed) {
            try await coordinator.revoke(scopeID: scopeID)
        }
    }

    func refresh() async {
        guard let coordinator else { return }
        await perform(operationError: .refreshFailed) {
            try await coordinator.refresh()
        }
    }

    func refreshIfNeeded() async {
        guard isBusy == false else { return }
        if hasUnavailableScope || summary == .failed {
            await refresh()
        }
    }

    func monitorUnavailableScopes() async {
        while Task.isCancelled == false {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard hasUnavailableScope else { continue }
            await refresh()
        }
    }

    func dismissOperationError() {
        operationError = nil
    }

    func handleCompositionFailure() {
        items = []
        summary = .failed
    }

#if DEBUG
    @discardableResult
    func loadUITestScenarioIfConfigured() -> Bool {
        guard let scenario = ProcessInfo.processInfo.environment["SPACETRACE_UI_TEST_SCENARIO"] else {
            return false
        }
        do {
            switch scenario {
            case "unconfigured":
                apply(.init(configuredScopeCount: 0, scopes: [], failures: []))
            case "authorized":
                apply(
                    try Self.debugReport(
                        authorized: [("scope-ui-authorized", "/Volumes/SpaceTraceFixture/Selected")]
                    )
                )
            case "unavailable":
                apply(
                    try Self.debugReport(
                        failures: [("scope-ui-unavailable", .resourceUnavailable)]
                    )
                )
            case "stale":
                apply(
                    try Self.debugReport(
                        failures: [("scope-ui-stale", .staleBookmark)]
                    )
                )
            case "multiple":
                apply(
                    try Self.debugReport(
                        authorized: [
                            ("scope-ui-a", "/Volumes/SpaceTraceFixture/A"),
                            ("scope-ui-b", "/Volumes/SpaceTraceFixture/B"),
                        ],
                        failures: [("scope-ui-stale", .staleBookmark)]
                    )
                )
            default:
                items = []
                summary = .failed
            }
        } catch {
            items = []
            summary = .failed
        }
        return true
    }

    private static func debugReport(
        authorized: [(String, String)] = [],
        failures: [(String, WatchedScopeRestorationFailureCode)] = []
    ) throws -> WatchedScopeRestorationReport {
        let scopes = try authorized.map { rawID, path in
            try WatchedScope(
                id: WatchedScopeID(rawID),
                root: DirtyRegionPath(path),
                mountPath: DirtyRegionPath("/")
            )
        }
        let restorationFailures = try failures.map { rawID, code in
            WatchedScopeRestorationFailure(
                scopeID: try WatchedScopeID(rawID),
                code: code
            )
        }
        return WatchedScopeRestorationReport(
            configuredScopeCount: scopes.count + restorationFailures.count,
            scopes: scopes,
            failures: restorationFailures
        )
    }
#endif

    private func perform(
        operationError failure: DirectoryAuthorizationOperationError,
        _ operation: () async throws -> WatchedScopeRestorationReport
    ) async {
        guard isBusy == false else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }
        do {
            apply(try await operation())
        } catch is CancellationError {
            return
        } catch {
            operationError = failure
        }
    }

    private func apply(_ report: WatchedScopeRestorationReport) {
        let authorizedItems = report.scopes.map {
            DirectoryAuthorizationItem(
                id: $0.id,
                status: .authorized(path: $0.root.rawValue)
            )
        }
        let failedItems = report.failures.map {
            DirectoryAuthorizationItem(
                id: $0.scopeID,
                status: $0.code == .resourceUnavailable
                    ? .unavailable
                    : .requiresReauthorization(reason: $0.code)
            )
        }
        let projectedItems = (authorizedItems + failedItems)
            .sorted { $0.id.rawValue < $1.id.rawValue }
        let uniqueIDs = Set(projectedItems.map(\.id))

        guard uniqueIDs.count == projectedItems.count,
              projectedItems.count == report.configuredScopeCount else {
            items = []
            summary = .failed
            return
        }

        items = projectedItems
        let authorizedCount = authorizedItems.count
        let issueCount = failedItems.count
        if projectedItems.isEmpty {
            summary = .unconfigured
        } else if issueCount == 0 {
            summary = .ready(authorizedCount: authorizedCount)
        } else {
            summary = .needsAttention(
                authorizedCount: authorizedCount,
                issueCount: issueCount
            )
        }
    }
}
