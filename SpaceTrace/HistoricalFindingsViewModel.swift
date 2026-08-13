import Observation
import SpaceTraceApplication

enum HistoricalFindingsViewState: Equatable {
    case waitingForAuthorization
    case loading
    case loaded
    case failed
}

enum HistoricalFindingsOperationError: Equatable {
    case policyChangeFailed
}

struct HistoricalFindingScopeDisplay: Sendable, Equatable, Hashable {
    let scopeID: WatchedScopeID
    let path: String?
    let readiness: ReconciliationScopeReadiness

    init(
        scopeID: WatchedScopeID,
        path: String?,
        readiness: ReconciliationScopeReadiness = .ready
    ) {
        self.scopeID = scopeID
        self.path = path
        self.readiness = readiness
    }
}

@MainActor
@Observable
final class HistoricalFindingsViewModel {
    private var service: (any HistoricalFindingOverviewServing)?
    private var reconciliationLoader: (any ReconciliationStatusLoading)?
    private var scopeIDs: [WatchedScopeID] = []
    private var displayPaths: [WatchedScopeID: String] = [:]
    private var readinessByScope: [WatchedScopeID: ReconciliationScopeReadiness] = [:]
    private var loadGeneration = 0

    private(set) var state: HistoricalFindingsViewState = .waitingForAuthorization
    private(set) var overview: HistoricalFindingOverview?
    private(set) var reconciliationStatuses: [WatchedScopeID: ReconciliationStatus] = [:]
    private(set) var isChangingPolicy = false
    private(set) var operationError: HistoricalFindingsOperationError?

    init(
        service: (any HistoricalFindingOverviewServing)? = nil,
        reconciliationLoader: (any ReconciliationStatusLoading)? = nil
    ) {
        self.service = service
        self.reconciliationLoader = reconciliationLoader
    }

    func connect(_ service: any HistoricalFindingOverviewServing) {
        self.service = service
    }

    func connectReconciliationStatus(
        _ loader: any ReconciliationStatusLoading
    ) {
        reconciliationLoader = loader
    }

    func load(scopeIDs: [WatchedScopeID]) async {
        displayPaths = [:]
        readinessByScope = [:]
        for scopeID in scopeIDs where readinessByScope[scopeID] == nil {
            readinessByScope[scopeID] = .ready
        }
        self.scopeIDs = scopeIDs.sorted {
            $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8)
        }
        await performLoad()
    }

    func load(scopes: [HistoricalFindingScopeDisplay]) async {
        var paths: [WatchedScopeID: String] = [:]
        var readiness: [WatchedScopeID: ReconciliationScopeReadiness] = [:]
        for scope in scopes {
            if paths[scope.scopeID] == nil, let path = scope.path {
                paths[scope.scopeID] = path
            }
            if readiness[scope.scopeID] == nil {
                readiness[scope.scopeID] = scope.readiness
            }
        }
        displayPaths = paths
        readinessByScope = readiness
        scopeIDs = scopes.map(\.scopeID).sorted {
            $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8)
        }
        await performLoad()
    }

    func displayPath(for scopeID: WatchedScopeID) -> String? {
        displayPaths[scopeID]
    }

    func refresh() async {
        await performLoad()
    }

    func setHistoryEnabled(_ enabled: Bool) async {
        guard isChangingPolicy == false, let service else { return }
        isChangingPolicy = true
        operationError = nil
        defer { isChangingPolicy = false }
        do {
            try await service.setHistoryEnabled(enabled)
            await performLoad()
        } catch is CancellationError {
            return
        } catch {
            operationError = .policyChangeFailed
        }
    }

    func dismissOperationError() {
        operationError = nil
    }

    func handleCompositionFailure() {
        loadGeneration += 1
        overview = nil
        reconciliationStatuses = [:]
        state = .failed
    }

    private func performLoad() async {
        guard scopeIDs.isEmpty == false else {
            loadGeneration += 1
            overview = nil
            reconciliationStatuses = [:]
            state = .waitingForAuthorization
            return
        }
        guard let service else {
            handleCompositionFailure()
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        overview = nil
        state = .loading
        do {
            let result = try await service.loadFindingOverview(
                scopeIDs: scopeIDs,
                currentLimit: 10,
                auditLimit: 100
            )
            var statuses: [WatchedScopeID: ReconciliationStatus] = [:]
            if let reconciliationLoader {
                for scopeID in scopeIDs {
                    try Task.checkCancellation()
                    let status = try await reconciliationLoader.load(
                        scopeID: scopeID,
                        readiness: readinessByScope[scopeID] ?? .ready
                    )
                    guard statuses.updateValue(status, forKey: scopeID) == nil else {
                        throw HistoricalFindingsViewModelError.duplicateScopeID
                    }
                }
            }
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            overview = result
            reconciliationStatuses = statuses
            state = .loaded
        } catch is CancellationError {
            guard generation == loadGeneration else { return }
            overview = nil
            reconciliationStatuses = [:]
            state = .failed
        } catch {
            guard generation == loadGeneration else { return }
            overview = nil
            reconciliationStatuses = [:]
            state = .failed
        }
    }
}

private enum HistoricalFindingsViewModelError: Error {
    case duplicateScopeID
}
