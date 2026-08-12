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
    let path: String
}

@MainActor
@Observable
final class HistoricalFindingsViewModel {
    private var service: (any HistoricalFindingOverviewServing)?
    private var scopeIDs: [WatchedScopeID] = []
    private var displayPaths: [WatchedScopeID: String] = [:]
    private var loadGeneration = 0

    private(set) var state: HistoricalFindingsViewState = .waitingForAuthorization
    private(set) var overview: HistoricalFindingOverview?
    private(set) var isChangingPolicy = false
    private(set) var operationError: HistoricalFindingsOperationError?

    init(service: (any HistoricalFindingOverviewServing)? = nil) {
        self.service = service
    }

    func connect(_ service: any HistoricalFindingOverviewServing) {
        self.service = service
    }

    func load(scopeIDs: [WatchedScopeID]) async {
        displayPaths = [:]
        self.scopeIDs = scopeIDs.sorted {
            $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8)
        }
        await performLoad()
    }

    func load(scopes: [HistoricalFindingScopeDisplay]) async {
        var paths: [WatchedScopeID: String] = [:]
        for scope in scopes where paths[scope.scopeID] == nil {
            paths[scope.scopeID] = scope.path
        }
        displayPaths = paths
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
        state = .failed
    }

    private func performLoad() async {
        guard scopeIDs.isEmpty == false else {
            loadGeneration += 1
            overview = nil
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
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            overview = result
            state = .loaded
        } catch is CancellationError {
            guard generation == loadGeneration else { return }
            overview = nil
            state = .failed
        } catch {
            guard generation == loadGeneration else { return }
            overview = nil
            state = .failed
        }
    }
}
