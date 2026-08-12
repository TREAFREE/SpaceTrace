import SpaceTraceApplication
import SpaceTraceDomain
import Testing

struct HistoricalFindingOverviewQueryTests {
    @Test("History Off remains typed and never queries path-bearing findings")
    func historyOffShortCircuitsFindingReads() async throws {
        let scopeID = try WatchedScopeID("scope-disabled")
        let repository = HistoricalFindingOverviewRepositoryFake(
            policy: try HistoricalPathHistoryPolicy(retentionDays: 0),
            availability: [scopeID: .historyDisabled]
        )
        let overview = try await HistoricalFindingOverviewQuery(
            repository: repository
        ).loadFindingOverview(
            scopeIDs: [scopeID],
            currentLimit: 10,
            auditLimit: 100
        )

        #expect(overview.retentionDays == 0)
        #expect(overview.scopes.map(\.availability) == [.historyDisabled])
        #expect(overview.currentFindings.isEmpty)
        #expect(overview.invalidatedFindings.isEmpty)
        #expect(await repository.effectiveRequests.isEmpty)
        #expect(await repository.allAuditRequests.isEmpty)
        #expect(await repository.invalidatedAuditRequests.isEmpty)
    }

    @Test("Available scopes query current and audit views at the latest committed sequence")
    func loadsAvailableCurrentAndAuditViews() async throws {
        let scopeA = try WatchedScopeID("scope-a")
        let scopeB = try WatchedScopeID("scope-b")
        let repository = HistoricalFindingOverviewRepositoryFake(
            policy: try HistoricalPathHistoryPolicy(retentionDays: 30),
            availability: [
                scopeA: .available,
                scopeB: .baselineUnavailable,
            ]
        )

        let overview = try await HistoricalFindingOverviewQuery(
            repository: repository
        ).loadFindingOverview(
            scopeIDs: [scopeB, scopeA],
            currentLimit: 7,
            auditLimit: 23
        )

        #expect(overview.scopes.map(\.scopeID) == [scopeA, scopeB])
        #expect(overview.scopes.map(\.availability) == [.available, .baselineUnavailable])
        #expect(await repository.effectiveRequests == [
            FindingReadRequest(scopeID: try ScopeID("scope-a"), through: Int64.max, limit: 7),
        ])
        #expect(await repository.allAuditRequests.isEmpty)
        #expect(await repository.invalidatedAuditRequests == [
            FindingReadRequest(scopeID: try ScopeID("scope-a"), through: Int64.max, limit: 23),
        ])
    }

    @Test("History policy changes are explicit 0 or 30 day writes")
    func changesHistoryPolicyExplicitly() async throws {
        let repository = HistoricalFindingOverviewRepositoryFake(
            policy: try HistoricalPathHistoryPolicy(retentionDays: 30),
            availability: [:]
        )
        let query = HistoricalFindingOverviewQuery(repository: repository)

        try await query.setHistoryEnabled(false)
        try await query.setHistoryEnabled(true)

        #expect(await repository.writtenRetentionDays == [0, 30])
    }

    @Test("Duplicate scopes fail before touching persistence")
    func rejectsDuplicateScopes() async throws {
        let scopeID = try WatchedScopeID("scope-duplicate")
        let repository = HistoricalFindingOverviewRepositoryFake(
            policy: try HistoricalPathHistoryPolicy(retentionDays: 30),
            availability: [scopeID: .available]
        )

        await #expect(throws: HistoricalFindingOverviewQueryError.duplicateScopeID) {
            _ = try await HistoricalFindingOverviewQuery(repository: repository)
                .loadFindingOverview(
                    scopeIDs: [scopeID, scopeID],
                    currentLimit: 10,
                    auditLimit: 100
                )
        }
        #expect(await repository.policyReadCount == 0)
    }

    @Test("A durable finding ID cannot appear in two scope projections")
    func rejectsCrossScopeDuplicateFindingIDs() throws {
        let finding = try overviewItem(id: 41)
        let scopeA = try HistoricalFindingScopeOverview(
            scopeID: WatchedScopeID("scope-a"),
            availability: .available,
            currentFindings: [finding],
            invalidatedFindings: []
        )
        let scopeB = try HistoricalFindingScopeOverview(
            scopeID: WatchedScopeID("scope-b"),
            availability: .available,
            currentFindings: [],
            invalidatedFindings: [
                try overviewItem(
                    id: 41,
                    validity: .evidenceInvalidated(
                        at: ObservationInstant(millisecondsSince1970: 3_000)
                    )
                ),
            ]
        )

        #expect(throws: HistoricalFindingOverviewQueryError.duplicateFindingID) {
            _ = try HistoricalFindingOverview(
                retentionDays: 30,
                scopes: [scopeA, scopeB]
            )
        }
    }

    @Test("A positive retention policy cannot contain a disabled scope")
    func rejectsMixedPolicyEvidence() throws {
        let disabled = try HistoricalFindingScopeOverview(
            scopeID: WatchedScopeID("scope-disabled"),
            availability: .historyDisabled,
            currentFindings: [],
            invalidatedFindings: []
        )

        #expect(
            throws: HistoricalFindingOverviewQueryError
                .historyDisabledShapeMismatch
        ) {
            _ = try HistoricalFindingOverview(
                retentionDays: 30,
                scopes: [disabled]
            )
        }
    }
}

private func overviewItem(
    id: Int64,
    validity: HistoricalFindingOverviewItemValidity = .currentEffective
) throws -> HistoricalFindingOverviewItem {
    try HistoricalFindingOverviewItem(
        id: HistoricalFindingRecordID(id),
        kind: .growth,
        metric: .logical,
        inclusiveDeltaBytes: 1_024,
        rankingContributionBytes: 1_024,
        positiveRank: 1,
        baselinePath: "/Fixtures/Scope/Cache",
        comparisonPath: "/Fixtures/Scope/Cache",
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

private struct FindingReadRequest: Sendable, Equatable {
    let scopeID: ScopeID
    let through: Int64
    let limit: Int
}

private actor HistoricalFindingOverviewRepositoryFake:
    HistoricalFindingOverviewRepository
{
    let policy: HistoricalPathHistoryPolicy
    let availability: [WatchedScopeID: HistoricalPathHistoryAvailability]
    private(set) var policyReadCount = 0
    private(set) var effectiveRequests: [FindingReadRequest] = []
    private(set) var allAuditRequests: [FindingReadRequest] = []
    private(set) var invalidatedAuditRequests: [FindingReadRequest] = []
    private(set) var writtenRetentionDays: [Int] = []

    init(
        policy: HistoricalPathHistoryPolicy,
        availability: [WatchedScopeID: HistoricalPathHistoryAvailability]
    ) {
        self.policy = policy
        self.availability = availability
    }

    func historicalPathHistoryPolicy() -> HistoricalPathHistoryPolicy {
        policyReadCount += 1
        return policy
    }

    func historicalPathHistoryAvailability(
        for scopeID: ScopeID
    ) throws -> HistoricalPathHistoryAvailability {
        let watched = try WatchedScopeID(scopeID.rawValue)
        return availability[watched] ?? .baselineUnavailable
    }

    func effectiveHistoricalFindings(
        for scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence,
        limit: HistoricalFindingQueryLimit
    ) -> [EffectiveHistoricalFinding] {
        effectiveRequests.append(
            FindingReadRequest(
                scopeID: scopeID,
                through: comparisonSequence.rawValue,
                limit: limit.rawValue
            )
        )
        return []
    }

    func historicalFindingAuditRecords(
        for scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence,
        limit: HistoricalFindingQueryLimit
    ) -> [HistoricalFindingAuditRecord] {
        allAuditRequests.append(
            FindingReadRequest(
                scopeID: scopeID,
                through: comparisonSequence.rawValue,
                limit: limit.rawValue
            )
        )
        return []
    }

    func evidenceInvalidatedHistoricalFindingAuditRecords(
        for scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence,
        limit: HistoricalFindingQueryLimit
    ) -> [HistoricalFindingAuditRecord] {
        invalidatedAuditRequests.append(
            FindingReadRequest(
                scopeID: scopeID,
                through: comparisonSequence.rawValue,
                limit: limit.rawValue
            )
        )
        return []
    }

    func setHistoricalPathHistoryPolicy(
        _ policy: HistoricalPathHistoryPolicy
    ) {
        writtenRetentionDays.append(policy.retentionDays)
    }
}
