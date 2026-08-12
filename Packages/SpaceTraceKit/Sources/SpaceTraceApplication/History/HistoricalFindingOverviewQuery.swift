import Foundation
import SpaceTraceAttribution
import SpaceTraceDomain

public enum HistoricalFindingOverviewItemValidity: Sendable, Equatable {
    case currentEffective
    case evidenceInvalidated(at: ObservationInstant)
}

public enum HistoricalFindingOverviewClassification: Sendable, Equatable {
    case classified(
        category: StorageAttributionCategory,
        confidence: AttributionConfidence,
        ruleID: AttributionRuleID,
        ruleVersion: AttributionRuleVersion,
        catalogVersion: AttributionCatalogVersion,
        evidenceCode: AttributionEvidenceCode
    )
    case unknownNoMatchingRule(catalogVersion: AttributionCatalogVersion)
    case unknownAmbiguous(
        catalogVersion: AttributionCatalogVersion,
        ruleIDs: [AttributionRuleID]
    )

    init(decision: VersionedAttributionDecision) {
        switch decision.result {
        case .classified(let attribution):
            self = .classified(
                category: attribution.category,
                confidence: attribution.confidence,
                ruleID: attribution.ruleID,
                ruleVersion: attribution.ruleVersion,
                catalogVersion: decision.catalogVersion,
                evidenceCode: attribution.evidenceCode
            )
        case .unknown(.noMatchingRule):
            self = .unknownNoMatchingRule(
                catalogVersion: decision.catalogVersion
            )
        case .unknown(.ambiguous(let ruleIDs)):
            self = .unknownAmbiguous(
                catalogVersion: decision.catalogVersion,
                ruleIDs: ruleIDs
            )
        }
    }
}

/// A bounded, non-durable projection for the Overview. It copies the exact
/// historical wording and metric from the immutable draft; UI code never
/// reclassifies or recomputes an older finding.
public struct HistoricalFindingOverviewItem: Sendable, Equatable, Identifiable {
    public let id: HistoricalFindingRecordID
    public let kind: HistoricalFindingKind
    public let metric: StorageMetric
    public let inclusiveDeltaBytes: Int64
    public let rankingContributionBytes: Int64?
    public let positiveRank: Int?
    public let baselinePath: String
    public let comparisonPath: String
    public let baselineDisplayName: String
    public let comparisonDisplayName: String
    public let baselineTime: ObservationInstant
    public let comparisonTime: ObservationInstant
    public let classification: HistoricalFindingOverviewClassification
    public let validity: HistoricalFindingOverviewItemValidity

    public init(
        id: HistoricalFindingRecordID,
        kind: HistoricalFindingKind,
        metric: StorageMetric,
        inclusiveDeltaBytes: Int64,
        rankingContributionBytes: Int64?,
        positiveRank: Int?,
        baselinePath: String,
        comparisonPath: String,
        baselineDisplayName: String,
        comparisonDisplayName: String,
        baselineTime: ObservationInstant,
        comparisonTime: ObservationInstant,
        classification: HistoricalFindingOverviewClassification,
        validity: HistoricalFindingOverviewItemValidity
    ) throws(HistoricalFindingOverviewQueryError) {
        guard metric != .volumeAvailable else { throw .unsupportedMetric }
        guard baselinePath.isEmpty == false,
              comparisonPath.isEmpty == false,
              baselinePath.utf8.contains(0) == false,
              comparisonPath.utf8.contains(0) == false,
              baselineDisplayName.isEmpty == false,
              comparisonDisplayName.isEmpty == false else {
            throw .invalidDisplayEvidence
        }
        if let positiveRank, positiveRank <= 0 { throw .invalidPositiveRank }
        switch kind {
        case .growth where inclusiveDeltaBytes <= 0:
            throw .invalidDelta
        case .decrease where inclusiveDeltaBytes >= 0:
            throw .invalidDelta
        default:
            break
        }
        self.id = id
        self.kind = kind
        self.metric = metric
        self.inclusiveDeltaBytes = inclusiveDeltaBytes
        self.rankingContributionBytes = rankingContributionBytes
        self.positiveRank = positiveRank
        self.baselinePath = baselinePath
        self.comparisonPath = comparisonPath
        self.baselineDisplayName = baselineDisplayName
        self.comparisonDisplayName = comparisonDisplayName
        self.baselineTime = baselineTime
        self.comparisonTime = comparisonTime
        self.classification = classification
        self.validity = validity
    }

    init(
        finding: EffectiveHistoricalFinding,
        validity: HistoricalFindingOverviewItemValidity
    ) throws(HistoricalFindingOverviewQueryError) {
        let decision: VersionedAttributionDecision?
        switch finding.draft.kind {
        case .disappearance:
            decision = finding.draft.evidence.baselineClassificationDecision
        case .growth, .decrease, .appearance, .move:
            decision = finding.draft.evidence.comparisonClassificationDecision
        }
        guard let decision else { throw .missingClassificationEvidence }
        try self.init(
            id: finding.recordID,
            kind: finding.draft.kind,
            metric: finding.draft.evidence.metric,
            inclusiveDeltaBytes: finding.draft.inclusiveDelta.bytes,
            rankingContributionBytes: finding.draft.rankingContribution?.bytes,
            positiveRank: finding.positiveRank,
            baselinePath: finding.draft.evidence.baselinePath,
            comparisonPath: finding.draft.evidence.comparisonPath,
            baselineDisplayName: finding.draft.evidence.baselineDisplayName,
            comparisonDisplayName: finding.draft.evidence.comparisonDisplayName,
            baselineTime: finding.draft.evidence.baselineTime,
            comparisonTime: finding.draft.evidence.comparisonTime,
            classification: HistoricalFindingOverviewClassification(
                decision: decision
            ),
            validity: validity
        )
    }
}

public struct HistoricalFindingScopeOverview: Sendable, Equatable, Identifiable {
    public var id: WatchedScopeID { scopeID }
    public let scopeID: WatchedScopeID
    public let availability: HistoricalPathHistoryAvailability
    public let currentFindings: [HistoricalFindingOverviewItem]
    public let invalidatedFindings: [HistoricalFindingOverviewItem]

    public init(
        scopeID: WatchedScopeID,
        availability: HistoricalPathHistoryAvailability,
        currentFindings: [HistoricalFindingOverviewItem],
        invalidatedFindings: [HistoricalFindingOverviewItem]
    ) throws(HistoricalFindingOverviewQueryError) {
        guard availability == .available
                || (currentFindings.isEmpty && invalidatedFindings.isEmpty) else {
            throw .findingsWithoutAvailableHistory
        }
        guard currentFindings.allSatisfy({ $0.validity == .currentEffective }),
              invalidatedFindings.allSatisfy({ item in
                  if case .evidenceInvalidated = item.validity { return true }
                  return false
              }) else {
            throw .invalidFindingValidity
        }
        let IDs = currentFindings.map(\.id) + invalidatedFindings.map(\.id)
        guard Set(IDs).count == IDs.count else { throw .duplicateFindingID }
        self.scopeID = scopeID
        self.availability = availability
        self.currentFindings = currentFindings
        self.invalidatedFindings = invalidatedFindings
    }
}

public struct HistoricalFindingOverview: Sendable, Equatable {
    public let retentionDays: Int
    public let scopes: [HistoricalFindingScopeOverview]

    public var currentFindings: [HistoricalFindingOverviewItem] {
        scopes.flatMap(\.currentFindings)
    }

    public var invalidatedFindings: [HistoricalFindingOverviewItem] {
        scopes.flatMap(\.invalidatedFindings)
    }

    public init(
        retentionDays: Int,
        scopes: [HistoricalFindingScopeOverview]
    ) throws(HistoricalFindingOverviewQueryError) {
        guard (0...30).contains(retentionDays) else { throw .invalidRetentionDays }
        let scopeBytes = scopes.map { Data($0.scopeID.rawValue.utf8) }
        guard Set(scopeBytes).count == scopeBytes.count else { throw .duplicateScopeID }
        let findingIDs = scopes.flatMap { scope in
            scope.currentFindings.map(\.id) + scope.invalidatedFindings.map(\.id)
        }
        guard Set(findingIDs).count == findingIDs.count else {
            throw .duplicateFindingID
        }
        if retentionDays == 0 {
            guard scopes.allSatisfy({
                $0.availability == .historyDisabled
                    && $0.currentFindings.isEmpty
                    && $0.invalidatedFindings.isEmpty
            }) else {
                throw .historyDisabledShapeMismatch
            }
        } else if scopes.contains(where: { $0.availability == .historyDisabled }) {
            throw .historyDisabledShapeMismatch
        }
        self.retentionDays = retentionDays
        self.scopes = scopes
    }
}

public protocol HistoricalFindingOverviewLoading: Sendable {
    func loadFindingOverview(
        scopeIDs: [WatchedScopeID],
        currentLimit: Int,
        auditLimit: Int
    ) async throws -> HistoricalFindingOverview
}

public protocol HistoricalPathHistoryControlling: Sendable {
    func setHistoryEnabled(_ enabled: Bool) async throws
}

public protocol HistoricalFindingOverviewServing:
    HistoricalFindingOverviewLoading,
    HistoricalPathHistoryControlling
{}

public struct HistoricalFindingOverviewQuery:
    HistoricalFindingOverviewServing,
    Sendable
{
    private let repository: any HistoricalFindingOverviewRepository

    public init(repository: any HistoricalFindingOverviewRepository) {
        self.repository = repository
    }

    public func loadFindingOverview(
        scopeIDs: [WatchedScopeID],
        currentLimit: Int,
        auditLimit: Int
    ) async throws -> HistoricalFindingOverview {
        guard scopeIDs.count <= AuthorizedBaselineScanRequest.maximumScopeCount else {
            throw HistoricalFindingOverviewQueryError.tooManyScopes
        }
        let scopeBytes = scopeIDs.map { Data($0.rawValue.utf8) }
        guard Set(scopeBytes).count == scopeBytes.count else {
            throw HistoricalFindingOverviewQueryError.duplicateScopeID
        }
        let currentQueryLimit = try HistoricalFindingQueryLimit(currentLimit)
        let auditQueryLimit = try HistoricalFindingQueryLimit(auditLimit)
        let latest = try ObservationCommitSequence(Int64.max)
        let policy = try await repository.historicalPathHistoryPolicy()
        let orderedScopeIDs = scopeIDs.sorted {
            $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8)
        }
        if policy.retentionDays == 0 {
            return try HistoricalFindingOverview(
                retentionDays: 0,
                scopes: orderedScopeIDs.map {
                    try HistoricalFindingScopeOverview(
                        scopeID: $0,
                        availability: .historyDisabled,
                        currentFindings: [],
                        invalidatedFindings: []
                    )
                }
            )
        }

        var scopes: [HistoricalFindingScopeOverview] = []
        scopes.reserveCapacity(orderedScopeIDs.count)
        for watchedScopeID in orderedScopeIDs {
            try Task.checkCancellation()
            let scopeID = try ScopeID(watchedScopeID.rawValue)
            let availability = try await repository.historicalPathHistoryAvailability(
                for: scopeID
            )
            guard availability == .available else {
                scopes.append(
                    try HistoricalFindingScopeOverview(
                        scopeID: watchedScopeID,
                        availability: availability,
                        currentFindings: [],
                        invalidatedFindings: []
                    )
                )
                continue
            }

            let effective = try await repository.effectiveHistoricalFindings(
                for: scopeID,
                through: latest,
                limit: currentQueryLimit
            )
            let invalidatedAudit = try await repository
                .evidenceInvalidatedHistoricalFindingAuditRecords(
                for: scopeID,
                through: latest,
                limit: auditQueryLimit
            )
            scopes.append(
                try HistoricalFindingScopeOverview(
                    scopeID: watchedScopeID,
                    availability: .available,
                    currentFindings: try effective.map {
                        try HistoricalFindingOverviewItem(
                            finding: $0,
                            validity: .currentEffective
                        )
                    },
                    invalidatedFindings: try invalidatedAudit.map { record in
                        guard let retraction = record.retraction else {
                            throw HistoricalFindingOverviewQueryError
                                .invalidFindingValidity
                        }
                        return try HistoricalFindingOverviewItem(
                            finding: record.finding,
                            validity: .evidenceInvalidated(at: retraction.committedAt)
                        )
                    }
                )
            )
        }
        return try HistoricalFindingOverview(
            retentionDays: policy.retentionDays,
            scopes: scopes
        )
    }

    public func setHistoryEnabled(_ enabled: Bool) async throws {
        try await repository.setHistoricalPathHistoryPolicy(
            HistoricalPathHistoryPolicy(retentionDays: enabled ? 30 : 0)
        )
    }
}

public enum HistoricalFindingOverviewQueryError: Error, Sendable, Equatable {
    case tooManyScopes
    case duplicateScopeID
    case invalidRetentionDays
    case historyDisabledShapeMismatch
    case findingsWithoutAvailableHistory
    case invalidFindingValidity
    case duplicateFindingID
    case invalidPositiveRank
    case invalidDelta
    case invalidDisplayEvidence
    case unsupportedMetric
    case missingClassificationEvidence
}
