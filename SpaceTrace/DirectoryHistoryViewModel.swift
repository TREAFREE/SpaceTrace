import Foundation
import Observation
import SpaceTraceApplication

enum DirectoryHistoryViewState: Equatable {
    case waitingForBaseline
    case loading
    case loaded
    case failed
}

@MainActor
@Observable
final class DirectoryHistoryViewModel {
    private var loader: (any DirectoryHistoryOverviewLoading)?
    private var contexts: [AuthorizedBaselineScanContext] = []
    private var loadGeneration = 0
    private let now: () -> Date

    private(set) var selectedWindow: DirectoryHistoryWindow
    private(set) var state: DirectoryHistoryViewState
    private(set) var overview: DirectoryHistoryOverview?

    init(
        loader: (any DirectoryHistoryOverviewLoading)? = nil,
        initialWindow: DirectoryHistoryWindow = .last24Hours,
        now: @escaping () -> Date = { Date() }
    ) {
        self.loader = loader
        selectedWindow = initialWindow
        state = .waitingForBaseline
        self.now = now
    }

    func connect(_ loader: any DirectoryHistoryOverviewLoading) {
        self.loader = loader
    }

    func load(contexts: [AuthorizedBaselineScanContext]) async {
        self.contexts = contexts.sorted { $0.scopeID.rawValue < $1.scopeID.rawValue }
        guard self.contexts.isEmpty == false else {
            loadGeneration += 1
            overview = nil
            state = .waitingForBaseline
            return
        }
        await performLoad()
    }

    func selectWindow(_ window: DirectoryHistoryWindow) async {
        guard selectedWindow != window else { return }
        selectedWindow = window
        guard contexts.isEmpty == false else { return }
        await performLoad()
    }

    func refresh() async {
        guard contexts.isEmpty == false else {
            state = .waitingForBaseline
            return
        }
        await performLoad()
    }

    func handleCompositionFailure() {
        loadGeneration += 1
        overview = nil
        state = .failed
    }

    private func performLoad() async {
        guard let loader else {
            handleCompositionFailure()
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        overview = nil
        state = .loading

        do {
            let result = try await loader.loadOverview(
                contexts: contexts,
                window: selectedWindow,
                through: now(),
                growthLimit: 100
            )
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            overview = result
            state = .loaded
        } catch is CancellationError {
            guard generation == loadGeneration else { return }
            overview = nil
            state = contexts.isEmpty ? .waitingForBaseline : .failed
        } catch {
            guard generation == loadGeneration else { return }
            overview = nil
            state = .failed
        }
    }
}
