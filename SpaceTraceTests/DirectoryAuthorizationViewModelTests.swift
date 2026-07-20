import Foundation
import SpaceTraceApplication
import Testing
@testable import SpaceTrace

@MainActor
struct DirectoryAuthorizationViewModelTests {
    @Test("An empty catalog presents a user-driven folder choice")
    func presentsUnconfiguredState() async {
        let model = DirectoryAuthorizationViewModel(
            picker: DirectoryPickerFake(selections: []),
            coordinator: AuthorizationCoordinatorFake(startReport: Self.emptyReport)
        )

        await model.start()

        #expect(model.summary == .unconfigured)
        #expect(model.items.isEmpty)
        #expect(model.authorizedScopeIDs.isEmpty)
        #expect(model.isBusy == false)
    }

    @Test("Adding directories creates distinct stable scopes and projects a sorted batch")
    func addsMultipleDirectories() async throws {
        let scopeB = try WatchedScopeID("scope-b")
        let scopeA = try WatchedScopeID("scope-a")
        let urlB = URL(fileURLWithPath: "/Volumes/Test/B", isDirectory: true)
        let urlA = URL(fileURLWithPath: "/Volumes/Test/A", isDirectory: true)
        let coordinator = AuthorizationCoordinatorFake(
            startReport: Self.emptyReport,
            authorizationReports: [
                try Self.report(authorized: [(scopeB, urlB.path)]),
                try Self.report(authorized: [(scopeB, urlB.path), (scopeA, urlA.path)]),
            ]
        )
        let idFactory = ScopeIDFactoryFake(ids: [scopeB, scopeA])
        let model = DirectoryAuthorizationViewModel(
            picker: DirectoryPickerFake(selections: [urlB, urlA]),
            coordinator: coordinator,
            makeScopeID: { try idFactory.next() }
        )
        await model.start()

        await model.addDirectory()
        await model.addDirectory()

        #expect(model.summary == .ready(authorizedCount: 2))
        #expect(model.items.map(\.id) == [scopeA, scopeB])
        #expect(model.authorizedScopeIDs == [scopeA, scopeB])
        #expect(await coordinator.authorizedScopeIDs == [scopeB, scopeA])
        #expect(await coordinator.selectedURLs == [urlB, urlA])
    }

    @Test("Stale restoration reauthorizes only the selected stable scope")
    func reauthorizesStaleScope() async throws {
        let scopeID = try WatchedScopeID("existing-scope")
        let staleReport = try Self.report(failures: [(scopeID, .staleBookmark)])
        let selectedURL = URL(fileURLWithPath: "/Volumes/Test/Reauthorized", isDirectory: true)
        let coordinator = AuthorizationCoordinatorFake(
            startReport: staleReport,
            authorizationReports: [
                try Self.report(authorized: [(scopeID, selectedURL.path)]),
            ]
        )
        let model = DirectoryAuthorizationViewModel(
            picker: DirectoryPickerFake(selections: [selectedURL]),
            coordinator: coordinator
        )
        await model.start()

        await model.reauthorize(scopeID: scopeID)

        #expect(await coordinator.authorizedScopeIDs == [scopeID])
        #expect(model.summary == .ready(authorizedCount: 1))
        #expect(model.items == [
            DirectoryAuthorizationItem(
                id: scopeID,
                status: .authorized(path: selectedURL.path)
            ),
        ])
    }

    @Test("A mixed report keeps healthy scopes usable while an external scope is absent")
    func refreshesOnlyUnavailableScopeState() async throws {
        let internalID = try WatchedScopeID("scope-internal")
        let externalID = try WatchedScopeID("scope-external")
        let initial = try Self.report(
            authorized: [(internalID, "/Users/example/Documents")],
            failures: [(externalID, .resourceUnavailable)]
        )
        let refreshed = try Self.report(
            authorized: [
                (internalID, "/Users/example/Documents"),
                (externalID, "/Volumes/External/Selected"),
            ]
        )
        let coordinator = AuthorizationCoordinatorFake(
            startReport: initial,
            refreshReports: [refreshed]
        )
        let model = DirectoryAuthorizationViewModel(
            picker: DirectoryPickerFake(selections: []),
            coordinator: coordinator
        )

        await model.start()
        #expect(model.summary == .needsAttention(authorizedCount: 1, issueCount: 1))
        #expect(model.authorizedScopeIDs == [internalID])
        #expect(model.hasUnavailableScope)

        await model.refresh()

        #expect(model.summary == .ready(authorizedCount: 2))
        #expect(model.authorizedScopeIDs == [externalID, internalID])
        #expect(model.hasUnavailableScope == false)
        #expect(await coordinator.refreshCount == 1)
    }

    @Test("Revocation removes only the selected scope")
    func revokesOneScope() async throws {
        let scopeA = try WatchedScopeID("scope-a")
        let scopeB = try WatchedScopeID("scope-b")
        let coordinator = AuthorizationCoordinatorFake(
            startReport: try Self.report(
                authorized: [
                    (scopeA, "/Volumes/Test/A"),
                    (scopeB, "/Volumes/Test/B"),
                ]
            ),
            revocationReports: [
                try Self.report(authorized: [(scopeB, "/Volumes/Test/B")]),
            ]
        )
        let model = DirectoryAuthorizationViewModel(
            picker: DirectoryPickerFake(selections: []),
            coordinator: coordinator
        )
        await model.start()

        await model.revoke(scopeID: scopeA)

        #expect(model.summary == .ready(authorizedCount: 1))
        #expect(model.items.map(\.id) == [scopeB])
        #expect(await coordinator.revokedScopeIDs == [scopeA])
    }

    @Test("Cancelling the system picker leaves every existing scope unchanged")
    func preservesStateWhenPickerIsCancelled() async throws {
        let scopeID = try WatchedScopeID("scope-existing")
        let initial = try Self.report(
            authorized: [(scopeID, "/Volumes/Test/Selected")]
        )
        let coordinator = AuthorizationCoordinatorFake(startReport: initial)
        let model = DirectoryAuthorizationViewModel(
            picker: DirectoryPickerFake(selections: [nil]),
            coordinator: coordinator
        )
        await model.start()

        await model.reauthorize(scopeID: scopeID)

        #expect(model.summary == .ready(authorizedCount: 1))
        #expect(model.items.map(\.id) == [scopeID])
        #expect(await coordinator.authorizedScopeIDs.isEmpty)
    }

    @Test("A failed mutation preserves the last verified catalog projection")
    func preservesStateAfterMutationFailure() async throws {
        let existingID = try WatchedScopeID("scope-existing")
        let newID = try WatchedScopeID("scope-new")
        let selectedURL = URL(fileURLWithPath: "/Volumes/Test/New", isDirectory: true)
        let coordinator = AuthorizationCoordinatorFake(
            startReport: try Self.report(
                authorized: [(existingID, "/Volumes/Test/Existing")]
            )
        )
        let model = DirectoryAuthorizationViewModel(
            picker: DirectoryPickerFake(selections: [selectedURL]),
            coordinator: coordinator,
            makeScopeID: { newID }
        )
        await model.start()

        await model.addDirectory()

        #expect(model.summary == .ready(authorizedCount: 1))
        #expect(model.items.map(\.id) == [existingID])
        #expect(model.operationError == .authorizationFailed)
    }

    @Test("A report count mismatch fails closed instead of hiding a configured scope")
    func rejectsIncompleteProjection() async throws {
        let scopeID = try WatchedScopeID("scope-visible")
        let malformed = WatchedScopeRestorationReport(
            configuredScopeCount: 2,
            scopes: [try Self.scope(id: scopeID, root: "/Volumes/Test/Visible")],
            failures: []
        )
        let model = DirectoryAuthorizationViewModel(
            picker: DirectoryPickerFake(selections: []),
            coordinator: AuthorizationCoordinatorFake(startReport: malformed)
        )

        await model.start()

        #expect(model.summary == .failed)
        #expect(model.items.isEmpty)
        #expect(model.canAddDirectory == false)
    }

    @Test("The UI request cap is enforced before opening another system picker")
    func enforcesScopeLimit() async throws {
        let configured = try (0..<AuthorizedBaselineScanRequest.maximumScopeCount).map { index in
            let scopeID = try WatchedScopeID("scope-\(index)")
            return (scopeID, "/Volumes/Test/\(index)")
        }
        let picker = DirectoryPickerFake(
            selections: [URL(fileURLWithPath: "/Volumes/Test/Extra", isDirectory: true)]
        )
        let model = DirectoryAuthorizationViewModel(
            picker: picker,
            coordinator: AuthorizationCoordinatorFake(
                startReport: try Self.report(authorized: configured)
            )
        )
        await model.start()

        await model.addDirectory()

        #expect(model.canAddDirectory == false)
        #expect(model.operationError == .scopeLimitReached)
        #expect(picker.selectionCount == 0)
    }

    private static let emptyReport = WatchedScopeRestorationReport(
        configuredScopeCount: 0,
        scopes: [],
        failures: []
    )

    private static func report(
        authorized: [(WatchedScopeID, String)] = [],
        failures: [(WatchedScopeID, WatchedScopeRestorationFailureCode)] = []
    ) throws -> WatchedScopeRestorationReport {
        WatchedScopeRestorationReport(
            configuredScopeCount: authorized.count + failures.count,
            scopes: try authorized.map { try scope(id: $0.0, root: $0.1) },
            failures: failures.map {
                WatchedScopeRestorationFailure(scopeID: $0.0, code: $0.1)
            }
        )
    }

    private static func scope(
        id: WatchedScopeID,
        root: String
    ) throws -> WatchedScope {
        try WatchedScope(
            id: id,
            root: DirtyRegionPath(root),
            mountPath: DirtyRegionPath("/")
        )
    }
}

@MainActor
private final class DirectoryPickerFake: DirectorySelecting {
    private var selections: [URL?]
    private(set) var selectionCount = 0

    init(selections: [URL?]) {
        self.selections = selections
    }

    func selectDirectory() -> URL? {
        selectionCount += 1
        guard selections.isEmpty == false else { return nil }
        return selections.removeFirst()
    }
}

@MainActor
private final class ScopeIDFactoryFake {
    private var ids: [WatchedScopeID]

    init(ids: [WatchedScopeID]) {
        self.ids = ids
    }

    func next() throws -> WatchedScopeID {
        guard ids.isEmpty == false else {
            throw AuthorizationViewModelFixtureError.missingScopeID
        }
        return ids.removeFirst()
    }
}

private actor AuthorizationCoordinatorFake: WatchedScopeAuthorizationCoordinating {
    let startReport: WatchedScopeRestorationReport
    private var authorizationReports: [WatchedScopeRestorationReport]
    private var refreshReports: [WatchedScopeRestorationReport]
    private var revocationReports: [WatchedScopeRestorationReport]
    private(set) var selectedURLs: [URL] = []
    private(set) var authorizedScopeIDs: [WatchedScopeID] = []
    private(set) var revokedScopeIDs: [WatchedScopeID] = []
    private(set) var refreshCount = 0

    init(
        startReport: WatchedScopeRestorationReport,
        authorizationReports: [WatchedScopeRestorationReport] = [],
        refreshReports: [WatchedScopeRestorationReport] = [],
        revocationReports: [WatchedScopeRestorationReport] = []
    ) {
        self.startReport = startReport
        self.authorizationReports = authorizationReports
        self.refreshReports = refreshReports
        self.revocationReports = revocationReports
    }

    func start() -> WatchedScopeRestorationReport {
        startReport
    }

    func refresh() throws -> WatchedScopeRestorationReport {
        refreshCount += 1
        guard refreshReports.isEmpty == false else {
            throw AuthorizationViewModelFixtureError.missingReport
        }
        return refreshReports.removeFirst()
    }

    func authorize(
        selectedURL: URL,
        scopeID: WatchedScopeID
    ) throws -> WatchedScopeRestorationReport {
        selectedURLs.append(selectedURL)
        authorizedScopeIDs.append(scopeID)
        guard authorizationReports.isEmpty == false else {
            throw AuthorizationViewModelFixtureError.missingReport
        }
        return authorizationReports.removeFirst()
    }

    func revoke(scopeID: WatchedScopeID) throws -> WatchedScopeRestorationReport {
        revokedScopeIDs.append(scopeID)
        guard revocationReports.isEmpty == false else {
            throw AuthorizationViewModelFixtureError.missingReport
        }
        return revocationReports.removeFirst()
    }
}

private enum AuthorizationViewModelFixtureError: Error {
    case missingReport
    case missingScopeID
}
