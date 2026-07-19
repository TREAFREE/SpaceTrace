import Foundation
import SpaceTraceApplication
import Testing
@testable import SpaceTrace

@MainActor
struct DirectoryAuthorizationViewModelTests {
    @Test("An empty catalog presents a user-driven folder choice")
    func presentsUnconfiguredState() async {
        let coordinator = AuthorizationCoordinatorFake(
            startReport: Self.emptyReport
        )
        let model = DirectoryAuthorizationViewModel(
            picker: DirectoryPickerFake(selection: nil),
            coordinator: coordinator
        )

        await model.start()

        #expect(model.status == .unconfigured)
        #expect(model.isBusy == false)
    }

    @Test("A selected directory becomes the exact displayed authorized root")
    func authorizesSelectedDirectory() async throws {
        let selectedURL = URL(
            fileURLWithPath: "/Volumes/SpaceTraceFixture/Selected",
            isDirectory: true
        )
        let scopeID = try WatchedScopeID("primary-user-selected")
        let authorizedReport = try Self.authorizedReport(
            scopeID: scopeID,
            root: selectedURL.path
        )
        let coordinator = AuthorizationCoordinatorFake(
            startReport: Self.emptyReport,
            authorizationReport: authorizedReport
        )
        let model = DirectoryAuthorizationViewModel(
            picker: DirectoryPickerFake(selection: selectedURL),
            coordinator: coordinator
        )
        await model.start()

        await model.chooseDirectory()

        #expect(model.status == .authorized(path: selectedURL.path))
        #expect(await coordinator.authorizedScopeIDs == [scopeID])
        #expect(await coordinator.selectedURLs == [selectedURL])
    }

    @Test("Stale restoration requires explicit reauthorization with the same scope identity")
    func reauthorizesStaleScope() async throws {
        let scopeID = try WatchedScopeID("existing-scope")
        let staleReport = WatchedScopeRestorationReport(
            configuredScopeCount: 1,
            scopes: [],
            failures: [
                WatchedScopeRestorationFailure(scopeID: scopeID, code: .staleBookmark),
            ]
        )
        let selectedURL = URL(fileURLWithPath: "/Volumes/Test/Reauthorized", isDirectory: true)
        let coordinator = AuthorizationCoordinatorFake(
            startReport: staleReport,
            authorizationReport: try Self.authorizedReport(
                scopeID: scopeID,
                root: selectedURL.path
            )
        )
        let model = DirectoryAuthorizationViewModel(
            picker: DirectoryPickerFake(selection: selectedURL),
            coordinator: coordinator
        )
        await model.start()

        #expect(model.status == .requiresReauthorization(reason: .staleBookmark))
        await model.chooseDirectory()

        #expect(await coordinator.authorizedScopeIDs == [scopeID])
        #expect(model.status == .authorized(path: selectedURL.path))
    }

    @Test("An unavailable external scope recovers on a later refresh")
    func refreshesExternalScopeReturn() async throws {
        let scopeID = try WatchedScopeID("external-scope")
        let unavailableReport = WatchedScopeRestorationReport(
            configuredScopeCount: 1,
            scopes: [],
            failures: [
                WatchedScopeRestorationFailure(scopeID: scopeID, code: .resourceUnavailable),
            ]
        )
        let coordinator = AuthorizationCoordinatorFake(
            startReport: unavailableReport,
            refreshReport: try Self.authorizedReport(
                scopeID: scopeID,
                root: "/Volumes/External/Selected"
            )
        )
        let model = DirectoryAuthorizationViewModel(
            picker: DirectoryPickerFake(selection: nil),
            coordinator: coordinator
        )
        await model.start()

        #expect(model.status == .unavailable)
        await model.refresh()

        #expect(model.status == .authorized(path: "/Volumes/External/Selected"))
        #expect(await coordinator.refreshCount == 1)
    }

    @Test("Revocation removes only the grant and returns to the empty state")
    func revokesGrant() async throws {
        let scopeID = try WatchedScopeID("scope-to-remove")
        let coordinator = AuthorizationCoordinatorFake(
            startReport: try Self.authorizedReport(
                scopeID: scopeID,
                root: "/Volumes/Test/Selected"
            ),
            revocationReport: Self.emptyReport
        )
        let model = DirectoryAuthorizationViewModel(
            picker: DirectoryPickerFake(selection: nil),
            coordinator: coordinator
        )
        await model.start()

        await model.revoke()

        #expect(model.status == .unconfigured)
        #expect(await coordinator.revokedScopeIDs == [scopeID])
    }

    @Test("Cancelling the system picker leaves the existing state unchanged")
    func preservesStateWhenPickerIsCancelled() async throws {
        let scopeID = try WatchedScopeID("scope-existing")
        let initial = try Self.authorizedReport(
            scopeID: scopeID,
            root: "/Volumes/Test/Selected"
        )
        let coordinator = AuthorizationCoordinatorFake(startReport: initial)
        let model = DirectoryAuthorizationViewModel(
            picker: DirectoryPickerFake(selection: nil),
            coordinator: coordinator
        )
        await model.start()

        await model.chooseDirectory()

        #expect(model.status == .authorized(path: "/Volumes/Test/Selected"))
        #expect(await coordinator.authorizedScopeIDs.isEmpty)
    }

    private static let emptyReport = WatchedScopeRestorationReport(
        configuredScopeCount: 0,
        scopes: [],
        failures: []
    )

    private static func authorizedReport(
        scopeID: WatchedScopeID,
        root: String
    ) throws -> WatchedScopeRestorationReport {
        WatchedScopeRestorationReport(
            configuredScopeCount: 1,
            scopes: [
                try WatchedScope(
                    id: scopeID,
                    root: DirtyRegionPath(root),
                    mountPath: DirtyRegionPath("/")
                ),
            ],
            failures: []
        )
    }
}

@MainActor
private struct DirectoryPickerFake: DirectorySelecting {
    let selection: URL?

    func selectDirectory() async -> URL? {
        selection
    }
}

private actor AuthorizationCoordinatorFake: WatchedScopeAuthorizationCoordinating {
    let startReport: WatchedScopeRestorationReport
    let authorizationReport: WatchedScopeRestorationReport?
    let refreshReport: WatchedScopeRestorationReport?
    let revocationReport: WatchedScopeRestorationReport?
    private(set) var selectedURLs: [URL] = []
    private(set) var authorizedScopeIDs: [WatchedScopeID] = []
    private(set) var revokedScopeIDs: [WatchedScopeID] = []
    private(set) var refreshCount = 0

    init(
        startReport: WatchedScopeRestorationReport,
        authorizationReport: WatchedScopeRestorationReport? = nil,
        refreshReport: WatchedScopeRestorationReport? = nil,
        revocationReport: WatchedScopeRestorationReport? = nil
    ) {
        self.startReport = startReport
        self.authorizationReport = authorizationReport
        self.refreshReport = refreshReport
        self.revocationReport = revocationReport
    }

    func start() -> WatchedScopeRestorationReport {
        startReport
    }

    func refresh() -> WatchedScopeRestorationReport {
        refreshCount += 1
        return refreshReport ?? startReport
    }

    func authorize(
        selectedURL: URL,
        scopeID: WatchedScopeID
    ) throws -> WatchedScopeRestorationReport {
        selectedURLs.append(selectedURL)
        authorizedScopeIDs.append(scopeID)
        guard let authorizationReport else {
            throw AuthorizationViewModelFixtureError.missingReport
        }
        return authorizationReport
    }

    func revoke(scopeID: WatchedScopeID) throws -> WatchedScopeRestorationReport {
        revokedScopeIDs.append(scopeID)
        guard let revocationReport else {
            throw AuthorizationViewModelFixtureError.missingReport
        }
        return revocationReport
    }
}

private enum AuthorizationViewModelFixtureError: Error {
    case missingReport
}
