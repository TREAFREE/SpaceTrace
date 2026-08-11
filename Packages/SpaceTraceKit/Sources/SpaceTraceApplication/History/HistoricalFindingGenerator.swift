import SpaceTraceDomain

/// Pure projection from two validated immutable directory frames to frozen,
/// coverage-aware historical finding drafts.
public struct HistoricalFindingGenerator: Sendable {
    public init() {}

    public func generate(
        baseline: HistoricalFindingObservationFrame,
        comparison: HistoricalFindingObservationFrame,
        positiveLimit: Int = 10
    ) throws -> HistoricalFindingGenerationResult {
        guard (1...100).contains(positiveLimit) else {
            throw HistoricalFindingGenerationError.invalidPositiveLimit(positiveLimit)
        }

        let algorithmVersion = HistoricalFindingAlgorithmVersion(validatedRawValue: 1)
        let rankingPolicyVersion = HistoricalFindingRankingPolicyVersion(validatedRawValue: 1)
        let baselineIndex = HistoricalFindingFrameIndex(frame: baseline)
        let comparisonIndex = HistoricalFindingFrameIndex(frame: comparison)

        let reusedEndpointIDs = Set(baseline.nodes.map(\.endpoint.id))
            .intersection(Set(comparison.nodes.map(\.endpoint.id)))
        if let reusedEndpointID = reusedEndpointIDs.min() {
            throw HistoricalFindingGenerationError.endpointIDReusedAcrossFrames(
                reusedEndpointID
            )
        }

        var findingSuppressions = HistoricalFindingReasonAccumulator()
        var rankingExclusions = HistoricalFindingReasonAccumulator()
        var collapses = HistoricalFindingReasonAccumulator()

        if let reason = frameIncompatibility(baseline: baseline, comparison: comparison) {
            findingSuppressions.add(reason)
            return makeResult(
                baselineIndex: baselineIndex,
                comparisonIndex: comparisonIndex,
                algorithmVersion: algorithmVersion,
                rankingPolicyVersion: rankingPolicyVersion,
                positiveLimit: positiveLimit,
                findings: [],
                rankedPositiveFindingKeys: [],
                findingSuppressions: findingSuppressions,
                rankingExclusions: rankingExclusions,
                collapses: collapses,
                truncatedPositiveCount: 0
            )
        }

        let subjects = Set(baselineIndex.nodesBySubject.keys)
            .union(comparisonIndex.nodesBySubject.keys)
            .sorted { binaryPrecedes($0.rawValue, $1.rawValue) }
        var unmatchedBaseline: [HistoricalFindingNode] = []
        var unmatchedComparison: [HistoricalFindingNode] = []
        var workingFindings: [HistoricalFindingWorkingDraft] = []
        var relocationCandidates: [HistoricalFindingRelocationCandidate] = []
        var appearedSubjects = Set<SubjectID>()
        var disappearedSubjects = Set<SubjectID>()

        for subject in subjects {
            let baselineNode = baselineIndex.nodesBySubject[subject]
            let comparisonNode = comparisonIndex.nodesBySubject[subject]
            switch (baselineNode, comparisonNode) {
            case let (.some(baselineNode), .some(comparisonNode)):
                switch comparisonNode.endpoint.compare(from: baselineNode.endpoint) {
                case .corrupt(.endpointIDReuse):
                    throw HistoricalFindingGenerationError.endpointIDReusedAcrossFrames(
                        baselineNode.endpoint.id
                    )
                case .incomparable(let reason):
                    findingSuppressions.add(findingReason(for: reason))
                case .comparable(let change):
                    let evidence = HistoricalFindingEvidence(
                        algorithmVersion: algorithmVersion,
                        rankingPolicyVersion: rankingPolicyVersion,
                        baseline: baselineNode,
                        comparison: comparisonNode
                    )
                    switch change.kind {
                    case .growth:
                        workingFindings.append(
                            HistoricalFindingWorkingDraft(
                                kind: .growth,
                                evidence: evidence,
                                inclusiveDelta: change.inclusiveDelta,
                                movementContext: nil,
                                baselineNode: baselineNode,
                                comparisonNode: comparisonNode
                            )
                        )
                    case .decrease:
                        workingFindings.append(
                            HistoricalFindingWorkingDraft(
                                kind: .decrease,
                                evidence: evidence,
                                inclusiveDelta: change.inclusiveDelta,
                                movementContext: nil,
                                baselineNode: baselineNode,
                                comparisonNode: comparisonNode
                            )
                        )
                    case .unchanged:
                        break
                    case .appearanceCandidate:
                        appearedSubjects.insert(subject)
                        workingFindings.append(
                            HistoricalFindingWorkingDraft(
                                kind: .appearance,
                                evidence: evidence,
                                inclusiveDelta: change.inclusiveDelta,
                                movementContext: nil,
                                baselineNode: baselineNode,
                                comparisonNode: comparisonNode
                            )
                        )
                    case .disappearanceCandidate:
                        disappearedSubjects.insert(subject)
                        workingFindings.append(
                            HistoricalFindingWorkingDraft(
                                kind: .disappearance,
                                evidence: evidence,
                                inclusiveDelta: change.inclusiveDelta,
                                movementContext: nil,
                                baselineNode: baselineNode,
                                comparisonNode: comparisonNode
                            )
                        )
                    case .relocationCandidate:
                        relocationCandidates.append(
                            HistoricalFindingRelocationCandidate(
                                change: change,
                                evidence: evidence,
                                baselineNode: baselineNode,
                                comparisonNode: comparisonNode
                            )
                        )
                    }
                }
            case let (.some(node), .none):
                unmatchedBaseline.append(node)
            case let (.none, .some(node)):
                unmatchedComparison.append(node)
            case (.none, .none):
                break
            }
        }

        var confirmedMoveOwnerBySubject: [SubjectID: HistoricalFindingKey] = [:]
        let relocationBySubject = Dictionary(
            uniqueKeysWithValues: relocationCandidates.map {
                ($0.baselineNode.endpoint.subjectID, $0)
            }
        )
        let relocationSubjects = Set(relocationBySubject.keys)
        var remainingDependencies: [SubjectID: Int] = [:]
        var dependentsBySubject: [SubjectID: [SubjectID]] = [:]
        var readyRelocations = HistoricalFindingRelocationReadyQueue()

        for (subject, candidate) in relocationBySubject {
            let dependencies = movingParentDependencies(
                for: candidate,
                baselineIndex: baselineIndex,
                comparisonIndex: comparisonIndex
            ).intersection(relocationSubjects)
            remainingDependencies[subject] = dependencies.count
            if dependencies.isEmpty {
                readyRelocations.insert(candidate)
            }
            for dependency in dependencies {
                dependentsBySubject[dependency, default: []].append(subject)
            }
        }

        var processedRelocationCount = 0
        while let candidate = readyRelocations.removeMinimum() {
            let subject = candidate.baselineNode.endpoint.subjectID
            processedRelocationCount += 1

            if let reason = moveSuppressionReason(
                for: candidate,
                baselineIndex: baselineIndex,
                comparisonIndex: comparisonIndex,
                confirmedMoveOwnerBySubject: confirmedMoveOwnerBySubject
            ) {
                findingSuppressions.add(reason)
            } else {
                let inheritedAncestorKey = inheritedMoveAncestorKey(
                    baselineNode: candidate.baselineNode,
                    comparisonNode: candidate.comparisonNode,
                    confirmedMoveOwnerBySubject: confirmedMoveOwnerBySubject
                )
                if let inheritedAncestorKey {
                    confirmedMoveOwnerBySubject[subject] = inheritedAncestorKey
                    switch candidate.change.inclusiveDelta.bytes {
                    case 0:
                        collapses.add(.collapsedImplicitDescendantMove)
                    case let bytes where bytes > 0:
                        collapses.add(.collapsedInheritedMoveFacet)
                        workingFindings.append(
                            HistoricalFindingWorkingDraft(
                                kind: .growth,
                                evidence: candidate.evidence,
                                inclusiveDelta: candidate.change.inclusiveDelta,
                                movementContext: .inheritedFromAncestor(inheritedAncestorKey),
                                baselineNode: candidate.baselineNode,
                                comparisonNode: candidate.comparisonNode
                            )
                        )
                    default:
                        collapses.add(.collapsedInheritedMoveFacet)
                        workingFindings.append(
                            HistoricalFindingWorkingDraft(
                                kind: .decrease,
                                evidence: candidate.evidence,
                                inclusiveDelta: candidate.change.inclusiveDelta,
                                movementContext: .inheritedFromAncestor(inheritedAncestorKey),
                                baselineNode: candidate.baselineNode,
                                comparisonNode: candidate.comparisonNode
                            )
                        )
                    }
                } else {
                    let moveKey = HistoricalFindingKey.make(
                        kind: .move,
                        evidence: candidate.evidence
                    )
                    confirmedMoveOwnerBySubject[subject] = moveKey
                    workingFindings.append(
                        HistoricalFindingWorkingDraft(
                            kind: .move,
                            evidence: candidate.evidence,
                            inclusiveDelta: candidate.change.inclusiveDelta,
                            movementContext: nil,
                            baselineNode: candidate.baselineNode,
                            comparisonNode: candidate.comparisonNode
                        )
                    )
                }
            }

            for dependentSubject in dependentsBySubject[subject, default: []] {
                guard let count = remainingDependencies[dependentSubject], count > 0 else {
                    continue
                }
                let updatedCount = count - 1
                remainingDependencies[dependentSubject] = updatedCount
                if updatedCount == 0,
                   let dependent = relocationBySubject[dependentSubject] {
                    readyRelocations.insert(dependent)
                }
            }
        }

        if processedRelocationCount < relocationCandidates.count {
            for _ in processedRelocationCount..<relocationCandidates.count {
                findingSuppressions.add(.moveParentEvidenceIncomplete)
            }
        }

        let descendantsOfAppearances = comparisonIndex.descendants(of: appearedSubjects)
        let descendantsOfDisappearances = baselineIndex.descendants(of: disappearedSubjects)
        for node in unmatchedBaseline {
            if descendantsOfDisappearances.contains(node.endpoint.subjectID) {
                collapses.add(.coveredByAncestorDisappearance)
            } else {
                findingSuppressions.add(.missingComparisonEndpoint)
            }
        }
        for node in unmatchedComparison {
            if descendantsOfAppearances.contains(node.endpoint.subjectID) {
                collapses.add(.coveredByAncestorAppearance)
            } else {
                findingSuppressions.add(.missingBaselineEndpoint)
            }
        }

        var findings: [HistoricalFindingDraft] = []
        var positiveCandidates: [HistoricalFindingDraft] = []
        for workingFinding in workingFindings {
            let rankingContribution: StorageDelta?
            switch workingFinding.kind {
            case .move:
                rankingContribution = nil
                rankingExclusions.add(.rankingKindIneligible)
            case .appearance, .disappearance:
                rankingContribution = workingFinding.inclusiveDelta
            case .growth, .decrease:
                switch try exclusiveContribution(
                    for: workingFinding,
                    baselineIndex: baselineIndex,
                    comparisonIndex: comparisonIndex
                ) {
                case .available(let value):
                    rankingContribution = value
                case .unavailable(let reason):
                    rankingContribution = nil
                    rankingExclusions.add(reason)
                }
            }

            let draft = HistoricalFindingDraft(
                kind: workingFinding.kind,
                evidence: workingFinding.evidence,
                inclusiveDelta: workingFinding.inclusiveDelta,
                rankingContribution: rankingContribution,
                movementContext: workingFinding.movementContext
            )
            findings.append(draft)

            guard workingFinding.kind != .move, rankingContribution != nil else {
                continue
            }
            guard let rankingContribution else { continue }
            guard workingFinding.kind == .growth || workingFinding.kind == .appearance else {
                rankingExclusions.add(
                    rankingContribution.bytes > 0
                        ? .rankingKindIneligible
                        : .rankingNonPositiveContribution
                )
                continue
            }
            guard rankingContribution.bytes > 0 else {
                rankingExclusions.add(.rankingNonPositiveContribution)
                continue
            }
            positiveCandidates.append(draft)
        }

        findings.sort { $0.key < $1.key }
        positiveCandidates.sort(by: stablePositiveFindingOrder)
        let truncatedPositiveCount = max(0, positiveCandidates.count - positiveLimit)
        let rankedPositiveFindingKeys = positiveCandidates
            .prefix(positiveLimit)
            .map(\.key)

        return makeResult(
            baselineIndex: baselineIndex,
            comparisonIndex: comparisonIndex,
            algorithmVersion: algorithmVersion,
            rankingPolicyVersion: rankingPolicyVersion,
            positiveLimit: positiveLimit,
            findings: findings,
            rankedPositiveFindingKeys: rankedPositiveFindingKeys,
            findingSuppressions: findingSuppressions,
            rankingExclusions: rankingExclusions,
            collapses: collapses,
            truncatedPositiveCount: truncatedPositiveCount
        )
    }
}

private struct HistoricalFindingFrameIndex {
    let frame: HistoricalFindingObservationFrame
    let rootNode: HistoricalFindingNode
    let nodesBySubject: [SubjectID: HistoricalFindingNode]
    let childrenByParentSubject: [SubjectID: [HistoricalFindingNode]]

    init(frame: HistoricalFindingObservationFrame) {
        self.frame = frame
        let nodesBySubject = Dictionary(
            uniqueKeysWithValues: frame.nodes.map { ($0.endpoint.subjectID, $0) }
        )
        self.nodesBySubject = nodesBySubject
        rootNode = nodesBySubject[frame.rootSubjectID] ?? frame.nodes[0]

        var childrenByParentSubject: [SubjectID: [HistoricalFindingNode]] = [:]
        for node in frame.nodes {
            guard let parentSubjectID = node.parentSubjectID else { continue }
            childrenByParentSubject[parentSubjectID, default: []].append(node)
        }
        self.childrenByParentSubject = childrenByParentSubject
    }

    func descendants(of roots: Set<SubjectID>) -> Set<SubjectID> {
        var descendants = Set<SubjectID>()
        var pending = roots.sorted { binaryPrecedes($0.rawValue, $1.rawValue) }
        var index = 0
        while index < pending.count {
            let parent = pending[index]
            index += 1
            for child in childrenByParentSubject[parent, default: []] {
                let subject = child.endpoint.subjectID
                if descendants.insert(subject).inserted {
                    pending.append(subject)
                }
            }
        }
        return descendants
    }
}

private struct HistoricalFindingWorkingDraft {
    let kind: HistoricalFindingKind
    let evidence: HistoricalFindingEvidence
    let inclusiveDelta: StorageDelta
    let movementContext: HistoricalFindingMovementContext?
    let baselineNode: HistoricalFindingNode
    let comparisonNode: HistoricalFindingNode
}

private struct HistoricalFindingRelocationCandidate {
    let change: StorageChange
    let evidence: HistoricalFindingEvidence
    let baselineNode: HistoricalFindingNode
    let comparisonNode: HistoricalFindingNode

    var provisionalKey: HistoricalFindingKey {
        HistoricalFindingKey.make(kind: .move, evidence: evidence)
    }
}

/// A deterministic binary min-heap used by the Kahn relocation scheduler.
/// Parent dependencies contribute at most two edges per candidate, so the
/// complete schedule is O(V log V + E) instead of repeatedly rescanning the
/// entire pending set for every level of a deep moved subtree.
private struct HistoricalFindingRelocationReadyQueue {
    private var storage: [HistoricalFindingRelocationCandidate] = []

    mutating func insert(_ candidate: HistoricalFindingRelocationCandidate) {
        storage.append(candidate)
        var child = storage.index(before: storage.endIndex)
        while child > storage.startIndex {
            let parent = (child - 1) / 2
            guard Self.precedes(storage[child], storage[parent]) else { break }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    mutating func removeMinimum() -> HistoricalFindingRelocationCandidate? {
        guard storage.isEmpty == false else { return nil }
        if storage.count == 1 {
            return storage.removeLast()
        }

        let minimum = storage[0]
        storage[0] = storage.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            guard left < storage.count else { break }
            let right = left + 1
            let smallerChild: Int
            if right < storage.count, Self.precedes(storage[right], storage[left]) {
                smallerChild = right
            } else {
                smallerChild = left
            }
            guard Self.precedes(storage[smallerChild], storage[parent]) else { break }
            storage.swapAt(parent, smallerChild)
            parent = smallerChild
        }
        return minimum
    }

    private static func precedes(
        _ lhs: HistoricalFindingRelocationCandidate,
        _ rhs: HistoricalFindingRelocationCandidate
    ) -> Bool {
        lhs.provisionalKey < rhs.provisionalKey
    }
}

private enum HistoricalFindingContributionOutcome {
    case available(StorageDelta)
    case unavailable(HistoricalFindingReason)
}

private struct HistoricalFindingReasonAccumulator {
    private var values: [HistoricalFindingReason: Int] = [:]

    mutating func add(_ reason: HistoricalFindingReason) {
        values[reason, default: 0] += 1
    }

    var canonicalCounts: [HistoricalFindingReasonCount] {
        values
            .map { HistoricalFindingReasonCount(reason: $0.key, count: $0.value) }
            .sorted { binaryPrecedes($0.reason.rawValue, $1.reason.rawValue) }
    }
}

private func frameIncompatibility(
    baseline: HistoricalFindingObservationFrame,
    comparison: HistoricalFindingObservationFrame
) -> HistoricalFindingReason? {
    guard baseline.rootSubjectID == comparison.rootSubjectID else {
        return .frameRootSubjectMismatch
    }
    guard baseline.scopeID == comparison.scopeID else { return .frameScopeMismatch }
    guard baseline.volumeID == comparison.volumeID else { return .frameVolumeMismatch }
    guard baseline.mountGenerationID == comparison.mountGenerationID else {
        return .frameMountGenerationMismatch
    }
    guard baseline.coverageEpochID == comparison.coverageEpochID else {
        return .frameCoverageEpochMismatch
    }
    guard baseline.metric == comparison.metric else { return .frameMetricMismatch }
    guard baseline.pathSemanticsVersion == comparison.pathSemanticsVersion else {
        return .framePathSemanticsMismatch
    }
    guard baseline.measurementSemanticsVersion == comparison.measurementSemanticsVersion else {
        return .frameMeasurementSemanticsMismatch
    }
    guard comparison.sequence > baseline.sequence else {
        return .frameNonIncreasingSequence
    }
    return nil
}

private func findingReason(
    for incomparability: ObservationIncomparability
) -> HistoricalFindingReason {
    switch incomparability {
    case .scopeMismatch:
        .endpointScopeMismatch
    case .volumeMismatch:
        .endpointVolumeMismatch
    case .mountGenerationMismatch:
        .endpointMountGenerationMismatch
    case .coverageEpochMismatch:
        .endpointCoverageEpochMismatch
    case .subjectMismatch:
        .endpointSubjectMismatch
    case .identityBasisMismatch:
        .endpointIdentityBasisMismatch
    case .metricMismatch:
        .endpointMetricMismatch
    case .pathSemanticsMismatch:
        .endpointPathSemanticsMismatch
    case .measurementSemanticsMismatch:
        .endpointMeasurementSemanticsMismatch
    case .nonIncreasingSequence:
        .endpointNonIncreasingSequence
    case .incompleteCoverage:
        .endpointIncompleteCoverage
    case .unavailable:
        .endpointUnavailable
    case .locationChangedWithoutStableIdentity:
        .endpointLocationChangedWithoutStableIdentity
    case .locationChangedWithoutTwoPresentEndpoints:
        .endpointLocationChangedWithoutTwoPresentEndpoints
    }
}

private func moveSuppressionReason(
    for candidate: HistoricalFindingRelocationCandidate,
    baselineIndex: HistoricalFindingFrameIndex,
    comparisonIndex: HistoricalFindingFrameIndex,
    confirmedMoveOwnerBySubject: [SubjectID: HistoricalFindingKey]
) -> HistoricalFindingReason? {
    guard let baselineEvidence = candidate.baselineNode.stableIdentityEvidence,
          let comparisonEvidence = candidate.comparisonNode.stableIdentityEvidence
    else {
        return .stableIdentityEvidenceMissing
    }
    guard baselineEvidence.reuseGuard == comparisonEvidence.reuseGuard else {
        return .stableIdentityReuseGuardMismatch
    }
    guard baselineEvidence.nodeKind == comparisonEvidence.nodeKind else {
        return .stableIdentityNodeKindMismatch
    }
    guard baselineEvidence.linkStatus == .unique,
          comparisonEvidence.linkStatus == .unique
    else {
        return .stableIdentityLinkSetNotUnique
    }
    guard let sourceParentSubject = candidate.baselineNode.parentSubjectID,
          let destinationParentSubject = candidate.comparisonNode.parentSubjectID
    else {
        return .moveParentEvidenceIncomplete
    }

    for parentSubject in Set([sourceParentSubject, destinationParentSubject]) {
        guard let baselineParent = baselineIndex.nodesBySubject[parentSubject],
              let comparisonParent = comparisonIndex.nodesBySubject[parentSubject],
              isCompleteMoveParent(baselineParent),
              isCompleteMoveParent(comparisonParent)
        else {
            return .moveParentEvidenceIncomplete
        }
        switch comparisonParent.endpoint.compare(from: baselineParent.endpoint) {
        case .comparable:
            break
        case .incomparable, .corrupt:
            return .moveParentEvidenceIncomplete
        }
        if baselineParent.endpoint.locationID != comparisonParent.endpoint.locationID,
           confirmedMoveOwnerBySubject[parentSubject] == nil {
            return .moveParentEvidenceIncomplete
        }
    }
    return nil
}

private func isCompleteMoveParent(_ node: HistoricalFindingNode) -> Bool {
    guard case .present(_, .complete) = node.endpoint.state else { return false }
    return node.directChildrenCoverage == .complete
}

private func inheritedMoveAncestorKey(
    baselineNode: HistoricalFindingNode,
    comparisonNode: HistoricalFindingNode,
    confirmedMoveOwnerBySubject: [SubjectID: HistoricalFindingKey]
) -> HistoricalFindingKey? {
    guard let baselineParent = baselineNode.parentSubjectID,
          baselineParent == comparisonNode.parentSubjectID,
          binaryEqual(
              directChildName(of: baselineNode.path),
              directChildName(of: comparisonNode.path)
          )
    else {
        return nil
    }
    return confirmedMoveOwnerBySubject[baselineParent]
}

private func movingParentDependencies(
    for candidate: HistoricalFindingRelocationCandidate,
    baselineIndex: HistoricalFindingFrameIndex,
    comparisonIndex: HistoricalFindingFrameIndex
) -> Set<SubjectID> {
    let parentSubjects = [
        candidate.baselineNode.parentSubjectID,
        candidate.comparisonNode.parentSubjectID,
    ].compactMap { $0 }
    return Set(parentSubjects.filter { subject in
        guard let baselineParent = baselineIndex.nodesBySubject[subject],
              let comparisonParent = comparisonIndex.nodesBySubject[subject]
        else {
            return false
        }
        return baselineParent.endpoint.locationID != comparisonParent.endpoint.locationID
    })
}

private func directChildName(of path: String) -> String {
    guard let separator = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: separator)...])
}

private func exclusiveContribution(
    for finding: HistoricalFindingWorkingDraft,
    baselineIndex: HistoricalFindingFrameIndex,
    comparisonIndex: HistoricalFindingFrameIndex
) throws -> HistoricalFindingContributionOutcome {
    guard finding.baselineNode.directChildrenCoverage == .complete,
          finding.comparisonNode.directChildrenCoverage == .complete
    else {
        return .unavailable(.rankingIncompleteDirectChildren)
    }

    let baselineChildren = baselineIndex.childrenByParentSubject[
        finding.baselineNode.endpoint.subjectID,
        default: []
    ]
    let comparisonChildren = comparisonIndex.childrenByParentSubject[
        finding.comparisonNode.endpoint.subjectID,
        default: []
    ]
    guard let baselineChildSum = try completeChildSum(baselineChildren),
          let comparisonChildSum = try completeChildSum(comparisonChildren)
    else {
        return .unavailable(.rankingIncompleteChildMeasurement)
    }

    let (childFlow, childFlowOverflow) = comparisonChildSum.subtractingReportingOverflow(
        baselineChildSum
    )
    guard childFlowOverflow == false else {
        throw HistoricalFindingGenerationError.arithmeticOverflow
    }
    let (exclusiveBytes, exclusiveOverflow) = finding.inclusiveDelta.bytes
        .subtractingReportingOverflow(childFlow)
    guard exclusiveOverflow == false else {
        throw HistoricalFindingGenerationError.arithmeticOverflow
    }
    return .available(storageDelta(metric: finding.evidence.metric, bytes: exclusiveBytes))
}

private func completeChildSum(
    _ children: [HistoricalFindingNode]
) throws -> Int64? {
    var sum: Int64 = 0
    for child in children {
        let bytes: Int64
        switch child.endpoint.state {
        case .present(let measuredBytes, .complete):
            bytes = measuredBytes.value
        case .absent:
            bytes = 0
        case .present, .unknown:
            return nil
        }
        let (updated, overflow) = sum.addingReportingOverflow(bytes)
        guard overflow == false else {
            throw HistoricalFindingGenerationError.arithmeticOverflow
        }
        sum = updated
    }
    return sum
}

private func storageDelta(metric: StorageMetric, bytes: Int64) -> StorageDelta {
    switch metric {
    case .logical:
        .logical(bytes: bytes)
    case .allocated:
        .allocated(bytes: bytes)
    case .volumeAvailable:
        .volumeAvailable(bytes: bytes)
    }
}

func stablePositiveFindingOrder(
    _ lhs: HistoricalFindingDraft,
    _ rhs: HistoricalFindingDraft
) -> Bool {
    let lhsBytes = lhs.rankingContribution?.bytes ?? Int64.min
    let rhsBytes = rhs.rankingContribution?.bytes ?? Int64.min
    if lhsBytes != rhsBytes { return lhsBytes > rhsBytes }
    if lhs.evidence.comparisonSequence != rhs.evidence.comparisonSequence {
        return lhs.evidence.comparisonSequence > rhs.evidence.comparisonSequence
    }
    if lhs.evidence.scopeID != rhs.evidence.scopeID {
        return binaryPrecedes(lhs.evidence.scopeID.rawValue, rhs.evidence.scopeID.rawValue)
    }
    let lhsLocation = reportingLocationID(for: lhs)
    let rhsLocation = reportingLocationID(for: rhs)
    if lhsLocation != rhsLocation {
        return lhsLocation < rhsLocation
    }
    return lhs.key < rhs.key
}

private func reportingLocationID(
    for finding: HistoricalFindingDraft
) -> ObservationLocationID {
    finding.kind == .disappearance
        ? finding.evidence.sourceLocationID
        : finding.evidence.destinationLocationID
}

private func makeResult(
    baselineIndex: HistoricalFindingFrameIndex,
    comparisonIndex: HistoricalFindingFrameIndex,
    algorithmVersion: HistoricalFindingAlgorithmVersion,
    rankingPolicyVersion: HistoricalFindingRankingPolicyVersion,
    positiveLimit: Int,
    findings: [HistoricalFindingDraft],
    rankedPositiveFindingKeys: [HistoricalFindingKey],
    findingSuppressions: HistoricalFindingReasonAccumulator,
    rankingExclusions: HistoricalFindingReasonAccumulator,
    collapses: HistoricalFindingReasonAccumulator,
    truncatedPositiveCount: Int
) -> HistoricalFindingGenerationResult {
    HistoricalFindingGenerationResult(
        batch: HistoricalFindingBatch(
            baselineRootEndpointID: baselineIndex.rootNode.endpoint.id,
            comparisonRootEndpointID: comparisonIndex.rootNode.endpoint.id,
            baselineSequence: baselineIndex.frame.sequence,
            comparisonSequence: comparisonIndex.frame.sequence,
            algorithmVersion: algorithmVersion,
            rankingPolicyVersion: rankingPolicyVersion,
            positiveLimit: positiveLimit,
            findings: findings,
            rankedPositiveFindingKeys: rankedPositiveFindingKeys
        ),
        suppressionSummary: HistoricalFindingSuppressionSummary(
            findingSuppressions: findingSuppressions.canonicalCounts,
            rankingExclusions: rankingExclusions.canonicalCounts,
            collapses: collapses.canonicalCounts,
            truncatedPositiveCount: truncatedPositiveCount
        )
    )
}
