import SpaceTraceApplication
import SpaceTraceDomain
import Testing
@testable import SpaceTrace

@MainActor
struct HistoricalFindingsViewModelTests {
    @Test("No authorized scope remains a distinct waiting state")
    func waitsForAuthorization() async {
        let service = HistoricalFindingOverviewServiceFake(responses: [])
        let model = HistoricalFindingsViewModel(service: service)

        await model.load(scopeIDs: [])

        #expect(model.state == .waitingForAuthorization)
        #expect(model.overview == nil)
        #expect(await service.requestedScopes.isEmpty)
    }

    @Test("Loaded current and invalidated evidence remains separately typed")
    func loadsOverview() async throws {
        let scopeID = try WatchedScopeID("scope-overview")
        let overview = try findingOverview(
            scopeID: scopeID,
            availability: .available,
            current: [findingItem(id: 1, validity: .currentEffective)],
            invalidated: [
                findingItem(
                    id: 2,
                    validity: .evidenceInvalidated(
                        at: try ObservationInstant(millisecondsSince1970: 3_000)
                    )
                ),
            ]
        )
        let service = HistoricalFindingOverviewServiceFake(
            responses: [.success(overview)]
        )
        let model = HistoricalFindingsViewModel(service: service)

        await model.load(scopeIDs: [scopeID])

        #expect(model.state == .loaded)
        #expect(model.overview == overview)
        #expect(model.overview?.currentFindings.count == 1)
        #expect(model.overview?.invalidatedFindings.count == 1)
    }

    @Test("A read failure is retryable without inventing an empty result")
    func reportsReadFailure() async throws {
        let service = HistoricalFindingOverviewServiceFake(responses: [.failure])
        let model = HistoricalFindingsViewModel(service: service)

        await model.load(scopeIDs: [try WatchedScopeID("scope-failure")])

        #expect(model.state == .failed)
        #expect(model.overview == nil)
    }

    @Test("Confirmed History Off reloads the typed disabled state")
    func disablesHistoryAndReloads() async throws {
        let scopeID = try WatchedScopeID("scope-policy")
        let before = try findingOverview(
            scopeID: scopeID,
            availability: .available,
            current: [],
            invalidated: []
        )
        let after = try findingOverview(
            scopeID: scopeID,
            retentionDays: 0,
            availability: .historyDisabled,
            current: [],
            invalidated: []
        )
        let service = HistoricalFindingOverviewServiceFake(
            responses: [.success(before), .success(after)]
        )
        let model = HistoricalFindingsViewModel(service: service)
        await model.load(scopeIDs: [scopeID])

        await model.setHistoryEnabled(false)

        #expect(await service.historyEnabledWrites == [false])
        #expect(model.state == .loaded)
        #expect(model.overview == after)
        #expect(model.operationError == nil)
    }

    @Test("A failed policy write preserves the last trustworthy result")
    func policyFailurePreservesOverview() async throws {
        let scopeID = try WatchedScopeID("scope-policy-failure")
        let overview = try findingOverview(
            scopeID: scopeID,
            availability: .available,
            current: [],
            invalidated: []
        )
        let service = HistoricalFindingOverviewServiceFake(
            responses: [.success(overview)],
            policyWriteFails: true
        )
        let model = HistoricalFindingsViewModel(service: service)
        await model.load(scopeIDs: [scopeID])

        await model.setHistoryEnabled(false)

        #expect(model.overview == overview)
        #expect(model.operationError == .policyChangeFailed)
        #expect(model.isChangingPolicy == false)
    }
}

private actor HistoricalFindingOverviewServiceFake: HistoricalFindingOverviewServing {
    enum Response: Sendable {
        case success(HistoricalFindingOverview)
        case failure
    }

    private var responses: [Response]
    private let policyWriteFails: Bool
    private(set) var requestedScopes: [[WatchedScopeID]] = []
    private(set) var historyEnabledWrites: [Bool] = []

    init(responses: [Response], policyWriteFails: Bool = false) {
        self.responses = responses
        self.policyWriteFails = policyWriteFails
    }

    func loadFindingOverview(
        scopeIDs: [WatchedScopeID],
        currentLimit: Int,
        auditLimit: Int
    ) throws -> HistoricalFindingOverview {
        #expect(currentLimit == 10)
        #expect(auditLimit == 100)
        requestedScopes.append(scopeIDs)
        guard responses.isEmpty == false else {
            throw HistoricalFindingsViewModelFixtureError.missingResponse
        }
        switch responses.removeFirst() {
        case let .success(overview):
            return overview
        case .failure:
            throw HistoricalFindingsViewModelFixtureError.loadFailed
        }
    }

    func setHistoryEnabled(_ enabled: Bool) throws {
        historyEnabledWrites.append(enabled)
        if policyWriteFails {
            throw HistoricalFindingsViewModelFixtureError.policyFailed
        }
    }
}

private enum HistoricalFindingsViewModelFixtureError: Error {
    case missingResponse
    case loadFailed
    case policyFailed
}

private func findingOverview(
    scopeID: WatchedScopeID,
    retentionDays: Int = 30,
    availability: HistoricalPathHistoryAvailability,
    current: [HistoricalFindingOverviewItem],
    invalidated: [HistoricalFindingOverviewItem]
) throws -> HistoricalFindingOverview {
    try HistoricalFindingOverview(
        retentionDays: retentionDays,
        scopes: [
            try HistoricalFindingScopeOverview(
                scopeID: scopeID,
                availability: availability,
                currentFindings: current,
                invalidatedFindings: invalidated
            ),
        ]
    )
}

private func findingItem(
    id: Int64,
    validity: HistoricalFindingOverviewItemValidity
) throws -> HistoricalFindingOverviewItem {
    try HistoricalFindingOverviewItem(
        id: HistoricalFindingRecordID(id),
        kind: .growth,
        metric: .logical,
        inclusiveDeltaBytes: 1_024,
        rankingContributionBytes: 1_024,
        positiveRank: 1,
        baselinePath: "/Fixtures/Cache",
        comparisonPath: "/Fixtures/Cache",
        baselineDisplayName: "Cache",
        comparisonDisplayName: "Cache",
        baselineTime: ObservationInstant(millisecondsSince1970: 1_000),
        comparisonTime: ObservationInstant(millisecondsSince1970: 2_000),
        classification: .unknownNoMatchingRule(
            catalogVersion: AttributionCatalogVersion(1)
        ),
        validity: validity
    )
}
