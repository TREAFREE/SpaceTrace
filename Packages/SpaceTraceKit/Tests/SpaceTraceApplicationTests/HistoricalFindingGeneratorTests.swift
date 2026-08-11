import Foundation
import Testing
import SpaceTraceAttribution
import SpaceTraceDomain
@testable import SpaceTraceApplication

struct HistoricalFindingGeneratorTests {
    @Test("Positive ranking limits are restricted to the documented safety range")
    func rejectsInvalidPositiveLimits() throws {
        let baseline = try makeFindingFrame(sequence: 1, endpointPrefix: "baseline")
        let comparison = try makeFindingFrame(sequence: 2, endpointPrefix: "comparison")
        let generator = HistoricalFindingGenerator()

        for invalidLimit in [0, 101] {
            #expect(throws: HistoricalFindingGenerationError.invalidPositiveLimit(invalidLimit)) {
                try generator.generate(
                    baseline: baseline,
                    comparison: comparison,
                    positiveLimit: invalidLimit
                )
            }
        }

        let result = try generator.generate(
            baseline: baseline,
            comparison: comparison,
            positiveLimit: 1
        )
        #expect(result.batch.positiveLimit == 1)
        #expect(result.batch.algorithmVersion.rawValue == 1)
        #expect(result.batch.rankingPolicyVersion.rawValue == 1)
        #expect(result.batch.baselineSequence.rawValue == 1)
        #expect(result.batch.comparisonSequence.rawValue == 2)
        #expect(result.batch.baselineRootEndpointID.rawValue == "baseline-root")
        #expect(result.batch.comparisonRootEndpointID.rawValue == "comparison-root")
    }

    @Test("Any endpoint ID reused across two frames is corruption before ordinary suppression")
    func rejectsGlobalEndpointIDReuseDeterministically() throws {
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            children: [
                .present(
                    subjectID: "baseline-a",
                    path: "/Fixtures/BaselineA",
                    bytes: 10,
                    endpointID: "shared-z"
                ),
                .present(
                    subjectID: "baseline-b",
                    path: "/Fixtures/BaselineB",
                    bytes: 10,
                    endpointID: "shared-a"
                ),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            children: [
                .present(
                    subjectID: "comparison-a",
                    path: "/Fixtures/ComparisonA",
                    bytes: 10,
                    endpointID: "shared-z"
                ),
                .present(
                    subjectID: "comparison-b",
                    path: "/Fixtures/ComparisonB",
                    bytes: 10,
                    endpointID: "shared-a"
                ),
            ]
        )

        #expect(
            throws: HistoricalFindingGenerationError.endpointIDReusedAcrossFrames(
                try ObservationEndpointID("shared-a")
            )
        ) {
            try HistoricalFindingGenerator().generate(
                baseline: baseline,
                comparison: comparison
            )
        }
    }

    @Test("Complete leaves produce growth and decrease while unchanged leaves stay silent")
    func generatesSimplePresentChanges() throws {
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            rootBytes: 100,
            children: [
                .present(subjectID: "grow", path: "/Fixtures/Grow", bytes: 10),
                .present(subjectID: "decrease", path: "/Fixtures/Decrease", bytes: 20),
                .present(subjectID: "unchanged", path: "/Fixtures/Unchanged", bytes: 30),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            rootBytes: 100,
            children: [
                .present(subjectID: "grow", path: "/Fixtures/Grow", bytes: 15),
                .present(subjectID: "decrease", path: "/Fixtures/Decrease", bytes: 12),
                .present(subjectID: "unchanged", path: "/Fixtures/Unchanged", bytes: 30),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )

        #expect(result.batch.findings.count == 2)
        let growth = try finding(
            comparisonEndpointID: "comparison-grow",
            in: result
        )
        #expect(growth.kind == .growth)
        #expect(growth.inclusiveDelta == .logical(bytes: 5))
        #expect(growth.rankingContribution == .logical(bytes: 5))
        #expect(growth.movementContext == nil)

        let decrease = try finding(
            comparisonEndpointID: "comparison-decrease",
            in: result
        )
        #expect(decrease.kind == .decrease)
        #expect(decrease.inclusiveDelta == .logical(bytes: -8))
        #expect(decrease.rankingContribution == .logical(bytes: -8))
        #expect(decrease.movementContext == nil)

        #expect(
            result.batch.findings.contains {
                $0.evidence.comparisonEndpointID.rawValue == "comparison-unchanged"
            } == false
        )
        #expect(result.batch.rankedPositiveFindingKeys == [growth.key])
        #expect(result.suppressionSummary.findingSuppressions.isEmpty)
        assertReasonCounts(
            result.suppressionSummary.rankingExclusions,
            equal: [(.rankingNonPositiveContribution, 1)]
        )
    }

    @Test("Validated explicit absence transitions become appearance and disappearance")
    func promotesExplicitAbsenceTransitions() throws {
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            rootBytes: 100,
            children: [
                .absent(subjectID: "appeared", path: "/Fixtures/Appeared"),
                .present(subjectID: "disappeared", path: "/Fixtures/Disappeared", bytes: 20),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            rootBytes: 100,
            children: [
                .present(subjectID: "appeared", path: "/Fixtures/Appeared", bytes: 15),
                .absent(subjectID: "disappeared", path: "/Fixtures/Disappeared"),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )

        #expect(result.batch.findings.count == 2)
        let appearance = try finding(
            comparisonEndpointID: "comparison-appeared",
            in: result
        )
        #expect(appearance.kind == .appearance)
        #expect(appearance.inclusiveDelta == .logical(bytes: 15))
        #expect(appearance.rankingContribution == .logical(bytes: 15))
        #expect(appearance.evidence.baselineClassificationDecision == nil)
        #expect(appearance.evidence.comparisonClassificationDecision != nil)

        let disappearance = try finding(
            comparisonEndpointID: "comparison-disappeared",
            in: result
        )
        #expect(disappearance.kind == .disappearance)
        #expect(disappearance.inclusiveDelta == .logical(bytes: -20))
        #expect(disappearance.evidence.baselineClassificationDecision != nil)
        #expect(disappearance.evidence.comparisonClassificationDecision == nil)
        #expect(result.batch.rankedPositiveFindingKeys == [appearance.key])
    }

    @Test("A unique guarded stable identity and complete parents promote one move")
    func promotesAProvenMove() throws {
        let stableEvidence = try uniqueStableEvidence(token: "generation-7")
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            children: [
                .present(
                    subjectID: "moved",
                    path: "/Fixtures/Old",
                    bytes: 40,
                    locationID: "location-old",
                    identityBasis: .stableFileSystemObject,
                    stableIdentityEvidence: stableEvidence
                ),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            children: [
                .present(
                    subjectID: "moved",
                    path: "/Fixtures/New",
                    bytes: 45,
                    locationID: "location-new",
                    identityBasis: .stableFileSystemObject,
                    stableIdentityEvidence: stableEvidence
                ),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )

        let move = try #require(result.batch.findings.only)
        #expect(move.kind == .move)
        #expect(move.inclusiveDelta == .logical(bytes: 5))
        #expect(move.rankingContribution == nil)
        #expect(move.movementContext == nil)
        #expect(move.evidence.sourceLocationID.rawValue == "location-old")
        #expect(move.evidence.destinationLocationID.rawValue == "location-new")
        #expect(move.evidence.baselineClassificationDecision != nil)
        #expect(move.evidence.comparisonClassificationDecision != nil)
        #expect(result.batch.rankedPositiveFindingKeys.isEmpty)
        assertReasonCounts(
            result.suppressionSummary.rankingExclusions,
            equal: [(.rankingKindIneligible, 1)]
        )
    }

    @Test("Rename-like evidence never becomes a move without every proof element")
    func suppressesUnprovenMoves() throws {
        let unique = try uniqueStableEvidence(token: "generation-a")
        let ambiguous = try HistoricalFindingStableIdentityEvidence(
            reuseGuard: .generationToken("generation-a"),
            nodeKind: .directory,
            linkStatus: .ambiguous
        )

        let missingEvidence = try generateMoveCandidate(
            baselineEvidence: nil,
            comparisonEvidence: nil
        )
        #expect(missingEvidence.batch.findings.isEmpty)
        assertReasonCounts(
            missingEvidence.suppressionSummary.findingSuppressions,
            equal: [(.stableIdentityEvidenceMissing, 1)]
        )

        let mismatchedGuard = try generateMoveCandidate(
            baselineEvidence: unique,
            comparisonEvidence: uniqueStableEvidence(token: "generation-b")
        )
        #expect(mismatchedGuard.batch.findings.isEmpty)
        assertReasonCounts(
            mismatchedGuard.suppressionSummary.findingSuppressions,
            equal: [(.stableIdentityReuseGuardMismatch, 1)]
        )

        let ambiguousLinkSet = try generateMoveCandidate(
            baselineEvidence: ambiguous,
            comparisonEvidence: ambiguous
        )
        #expect(ambiguousLinkSet.batch.findings.isEmpty)
        assertReasonCounts(
            ambiguousLinkSet.suppressionSummary.findingSuppressions,
            equal: [(.stableIdentityLinkSetNotUnique, 1)]
        )

        let incompleteParents = try generateMoveCandidate(
            baselineEvidence: unique,
            comparisonEvidence: unique,
            parentCoverage: .partial
        )
        #expect(incompleteParents.batch.findings.isEmpty)
        assertReasonCounts(
            incompleteParents.suppressionSummary.findingSuppressions,
            equal: [(.moveParentEvidenceIncomplete, 1)]
        )

        let pathIdentity = try generateMoveCandidate(
            identityBasis: .normalizedPath,
            baselineEvidence: nil,
            comparisonEvidence: nil
        )
        #expect(pathIdentity.batch.findings.contains { $0.kind == .move } == false)

        let crossMount = try generateMoveCandidate(
            baselineEvidence: unique,
            comparisonEvidence: unique,
            comparisonMountGenerationID: "mount-b"
        )
        #expect(crossMount.batch.findings.contains { $0.kind == .move } == false)
    }

    @Test("A scope root relocation is never promoted to a directory move")
    func suppressesRootRelocation() throws {
        let stableEvidence = try uniqueStableEvidence(token: "root-generation")
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            rootLocationID: "root-location-old",
            rootIdentityBasis: .stableFileSystemObject,
            rootStableIdentityEvidence: stableEvidence
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            rootLocationID: "root-location-new",
            rootIdentityBasis: .stableFileSystemObject,
            rootStableIdentityEvidence: stableEvidence
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )

        #expect(result.batch.findings.isEmpty)
        #expect(result.batch.rankedPositiveFindingKeys.isEmpty)
        assertReasonCounts(
            result.suppressionSummary.findingSuppressions,
            equal: [(.moveParentEvidenceIncomplete, 1)]
        )
    }

    @Test("Missing, partial, and unknown counterparts are suppressed instead of treated as zero")
    func suppressesUnavailableCounterparts() throws {
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            children: [
                .present(
                    subjectID: "missing-comparison",
                    path: "/Fixtures/MissingComparison",
                    bytes: 10
                ),
                .present(subjectID: "partial", path: "/Fixtures/Partial", bytes: 10),
                .present(subjectID: "unknown", path: "/Fixtures/Unknown", bytes: 10),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            children: [
                .present(
                    subjectID: "missing-baseline",
                    path: "/Fixtures/MissingBaseline",
                    bytes: 10
                ),
                .present(
                    subjectID: "partial",
                    path: "/Fixtures/Partial",
                    bytes: 12,
                    coverage: .partial
                ),
                .unknown(
                    subjectID: "unknown",
                    path: "/Fixtures/Unknown",
                    reason: .continuityGap
                ),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )

        #expect(result.batch.findings.isEmpty)
        assertReasonCounts(
            result.suppressionSummary.findingSuppressions,
            equal: sortedReasonCounts([
                (.missingBaselineEndpoint, 1),
                (.missingComparisonEndpoint, 1),
                (.endpointIncompleteCoverage, 1),
                (.endpointUnavailable, 1),
            ])
        )
        #expect(result.batch.rankedPositiveFindingKeys.isEmpty)
    }

    @Test("An ancestor move consumes unchanged implicit descendant moves")
    func collapsesImplicitDescendantMoves() throws {
        let evidence = try uniqueStableEvidence(token: "generation-tree")
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            children: [
                .present(
                    subjectID: "parent",
                    path: "/Fixtures/Old",
                    bytes: 100,
                    locationID: "location-parent-old",
                    identityBasis: .stableFileSystemObject,
                    stableIdentityEvidence: evidence
                ),
                .present(
                    subjectID: "child",
                    parentSubjectID: "parent",
                    path: "/Fixtures/Old/Child",
                    bytes: 40,
                    locationID: "location-child-old",
                    identityBasis: .stableFileSystemObject,
                    stableIdentityEvidence: evidence
                ),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            children: [
                .present(
                    subjectID: "parent",
                    path: "/Fixtures/New",
                    bytes: 100,
                    locationID: "location-parent-new",
                    identityBasis: .stableFileSystemObject,
                    stableIdentityEvidence: evidence
                ),
                .present(
                    subjectID: "child",
                    parentSubjectID: "parent",
                    path: "/Fixtures/New/Child",
                    bytes: 40,
                    locationID: "location-child-new",
                    identityBasis: .stableFileSystemObject,
                    stableIdentityEvidence: evidence
                ),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )

        let move = try #require(result.batch.findings.only)
        #expect(move.kind == .move)
        #expect(move.evidence.comparisonEndpointID.rawValue == "comparison-parent")
        assertReasonCounts(
            result.suppressionSummary.collapses,
            equal: [(.collapsedImplicitDescendantMove, 1)]
        )
    }

    @Test("A changed descendant keeps its byte facet while inheriting an ancestor move")
    func preservesNonzeroInheritedMovement() throws {
        let evidence = try uniqueStableEvidence(token: "generation-tree")
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            children: movedTreeFixtures(
                parentPath: "/Fixtures/Old",
                parentLocation: "location-parent-old",
                parentBytes: 100,
                childBytes: 40,
                childLocation: "location-child-old",
                evidence: evidence
            )
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            children: movedTreeFixtures(
                parentPath: "/Fixtures/New",
                parentLocation: "location-parent-new",
                parentBytes: 110,
                childBytes: 50,
                childLocation: "location-child-new",
                evidence: evidence
            )
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )
        let parentMove = try finding(
            comparisonEndpointID: "comparison-parent",
            in: result
        )
        let childGrowth = try finding(
            comparisonEndpointID: "comparison-child",
            in: result
        )

        #expect(parentMove.kind == .move)
        #expect(parentMove.movementContext == nil)
        #expect(childGrowth.kind == .growth)
        #expect(childGrowth.inclusiveDelta == .logical(bytes: 10))
        #expect(childGrowth.movementContext == .inheritedFromAncestor(parentMove.key))
        #expect(result.batch.rankedPositiveFindingKeys == [childGrowth.key])
        assertReasonCounts(
            result.suppressionSummary.collapses,
            equal: [(.collapsedInheritedMoveFacet, 1)]
        )
    }

    @Test("A descendant reparented independently remains a separate primary move")
    func preservesIndependentlyReparentedDescendantMove() throws {
        let evidence = try uniqueStableEvidence(token: "generation-tree")
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            children: [
                .present(
                    subjectID: "parent",
                    path: "/Fixtures/Old",
                    bytes: 100,
                    locationID: "location-parent-old",
                    identityBasis: .stableFileSystemObject,
                    stableIdentityEvidence: evidence
                ),
                .present(
                    subjectID: "other",
                    path: "/Fixtures/Other",
                    bytes: 50
                ),
                .present(
                    subjectID: "child",
                    parentSubjectID: "parent",
                    path: "/Fixtures/Old/Child",
                    bytes: 40,
                    locationID: "location-child-old",
                    identityBasis: .stableFileSystemObject,
                    stableIdentityEvidence: evidence
                ),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            children: [
                .present(
                    subjectID: "parent",
                    path: "/Fixtures/New",
                    bytes: 100,
                    locationID: "location-parent-new",
                    identityBasis: .stableFileSystemObject,
                    stableIdentityEvidence: evidence
                ),
                .present(
                    subjectID: "other",
                    path: "/Fixtures/Other",
                    bytes: 50
                ),
                .present(
                    subjectID: "child",
                    parentSubjectID: "other",
                    path: "/Fixtures/Other/Child",
                    bytes: 40,
                    locationID: "location-child-new",
                    identityBasis: .stableFileSystemObject,
                    stableIdentityEvidence: evidence
                ),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )
        let moves = result.batch.findings.filter { $0.kind == .move }

        #expect(moves.count == 2)
        #expect(moves.allSatisfy { $0.movementContext == nil })
        #expect(result.suppressionSummary.collapses.isEmpty)
    }

    @Test("Exclusive contribution prevents one child growth from being ranked twice")
    func ranksExclusiveParentChildContribution() throws {
        let fiveGiB: Int64 = 5 * 1_024 * 1_024 * 1_024
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            rootBytes: 10 * 1_024 * 1_024 * 1_024,
            children: [
                .present(
                    subjectID: "parent",
                    path: "/Fixtures/Parent",
                    bytes: Int64(10) * 1_024 * 1_024 * 1_024
                ),
                .present(
                    subjectID: "child",
                    parentSubjectID: "parent",
                    path: "/Fixtures/Parent/Child",
                    bytes: Int64(1) * 1_024 * 1_024 * 1_024
                ),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            rootBytes: 15 * 1_024 * 1_024 * 1_024,
            children: [
                .present(
                    subjectID: "parent",
                    path: "/Fixtures/Parent",
                    bytes: Int64(15) * 1_024 * 1_024 * 1_024
                ),
                .present(
                    subjectID: "child",
                    parentSubjectID: "parent",
                    path: "/Fixtures/Parent/Child",
                    bytes: Int64(6) * 1_024 * 1_024 * 1_024
                ),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )
        let root = try finding(comparisonEndpointID: "comparison-root", in: result)
        let parent = try finding(comparisonEndpointID: "comparison-parent", in: result)
        let child = try finding(comparisonEndpointID: "comparison-child", in: result)

        #expect(root.inclusiveDelta == .logical(bytes: fiveGiB))
        #expect(root.rankingContribution == .logical(bytes: 0))
        #expect(parent.inclusiveDelta == .logical(bytes: fiveGiB))
        #expect(parent.rankingContribution == .logical(bytes: 0))
        #expect(child.rankingContribution == .logical(bytes: fiveGiB))
        #expect(result.batch.rankedPositiveFindingKeys == [child.key])
        assertReasonCounts(
            result.suppressionSummary.rankingExclusions,
            equal: [(.rankingNonPositiveContribution, 2)]
        )
    }

    @Test("Opposite child flow remains signed when calculating parent exclusivity")
    func handlesOppositeParentChildDeltas() throws {
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            rootBytes: 100,
            children: [
                .present(subjectID: "parent", path: "/Fixtures/Parent", bytes: 50),
                .present(
                    subjectID: "child",
                    parentSubjectID: "parent",
                    path: "/Fixtures/Parent/Child",
                    bytes: 20
                ),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            rootBytes: 110,
            children: [
                .present(subjectID: "parent", path: "/Fixtures/Parent", bytes: 60),
                .present(
                    subjectID: "child",
                    parentSubjectID: "parent",
                    path: "/Fixtures/Parent/Child",
                    bytes: 15
                ),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )
        let parent = try finding(comparisonEndpointID: "comparison-parent", in: result)
        let child = try finding(comparisonEndpointID: "comparison-child", in: result)

        #expect(parent.inclusiveDelta == .logical(bytes: 10))
        #expect(parent.rankingContribution == .logical(bytes: 15))
        #expect(child.inclusiveDelta == .logical(bytes: -5))
        #expect(child.rankingContribution == .logical(bytes: -5))
        #expect(result.batch.rankedPositiveFindingKeys == [parent.key])
    }

    @Test("Incomplete immediate-child enumeration makes only that branch ranking-incomparable")
    func suppressesRankingWithoutCompleteChildFrame() throws {
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            rootBytes: 100,
            children: [
                .present(
                    subjectID: "parent",
                    path: "/Fixtures/Parent",
                    bytes: 50,
                    directChildrenCoverage: .partial
                ),
                .present(
                    subjectID: "child",
                    parentSubjectID: "parent",
                    path: "/Fixtures/Parent/Child",
                    bytes: 10
                ),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            rootBytes: 105,
            children: [
                .present(
                    subjectID: "parent",
                    path: "/Fixtures/Parent",
                    bytes: 55,
                    directChildrenCoverage: .partial
                ),
                .present(
                    subjectID: "child",
                    parentSubjectID: "parent",
                    path: "/Fixtures/Parent/Child",
                    bytes: 15
                ),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )
        let parent = try finding(comparisonEndpointID: "comparison-parent", in: result)
        let child = try finding(comparisonEndpointID: "comparison-child", in: result)

        #expect(parent.rankingContribution == nil)
        #expect(child.rankingContribution == .logical(bytes: 5))
        #expect(result.batch.rankedPositiveFindingKeys == [child.key])
        assertReasonCounts(
            result.suppressionSummary.rankingExclusions,
            equal: sortedReasonCounts([
                (.rankingIncompleteDirectChildren, 1),
                (.rankingNonPositiveContribution, 1),
            ])
        )
    }

    @Test("Stable Top N uses exclusive bytes and reports exact truncation")
    func returnsStableTopTen() throws {
        let baselineChildren = (1...12).map { index in
            FindingNodeFixture.present(
                subjectID: "child-\(index)",
                path: "/Fixtures/Child\(index)",
                bytes: 100,
                locationID: String(format: "location-%02d", index)
            )
        }
        let comparisonChildren = (1...12).map { index in
            FindingNodeFixture.present(
                subjectID: "child-\(index)",
                path: "/Fixtures/Child\(index)",
                bytes: 100 + Int64(index),
                locationID: String(format: "location-%02d", index)
            )
        }
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            rootBytes: 1_000,
            children: baselineChildren
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            rootBytes: 1_078,
            children: comparisonChildren
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison,
            positiveLimit: 10
        )
        let expectedKeys = try stride(from: 12, through: 3, by: -1).map { index in
            try finding(
                comparisonEndpointID: "comparison-child-\(index)",
                in: result
            ).key
        }

        #expect(result.batch.rankedPositiveFindingKeys == expectedKeys)
        #expect(result.suppressionSummary.truncatedPositiveCount == 2)
        assertReasonCounts(
            result.suppressionSummary.rankingExclusions,
            equal: [(.rankingNonPositiveContribution, 1)]
        )
    }

    @Test("Equal positive contributions use opaque location IDs rather than display paths")
    func usesStableBinaryRankingTieBreakers() throws {
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            rootBytes: 100,
            children: [
                .present(
                    subjectID: "z-path",
                    path: "/Fixtures/A-Display-First",
                    bytes: 10,
                    locationID: "location-z"
                ),
                .present(
                    subjectID: "a-path",
                    path: "/Fixtures/Z-Display-Last",
                    bytes: 10,
                    locationID: "location-a"
                ),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            rootBytes: 102,
            children: [
                .present(
                    subjectID: "z-path",
                    path: "/Fixtures/A-Display-First",
                    bytes: 11,
                    locationID: "location-z"
                ),
                .present(
                    subjectID: "a-path",
                    path: "/Fixtures/Z-Display-Last",
                    bytes: 11,
                    locationID: "location-a"
                ),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )
        let locationA = try finding(
            comparisonEndpointID: "comparison-a-path",
            in: result
        )
        let locationZ = try finding(
            comparisonEndpointID: "comparison-z-path",
            in: result
        )

        #expect(result.batch.rankedPositiveFindingKeys == [locationA.key, locationZ.key])
    }

    @Test("Stable comparator orders equal contributions by sequence then binary scope")
    func usesSequenceAndScopeRankingTieBreakers() throws {
        let older = try rankingFixtureDraft(
            baselineSequence: 1,
            comparisonSequence: 2,
            endpointPrefix: "older",
            scopeID: "scope-z"
        )
        let newer = try rankingFixtureDraft(
            baselineSequence: 2,
            comparisonSequence: 3,
            endpointPrefix: "newer",
            scopeID: "scope-z"
        )

        #expect(stablePositiveFindingOrder(newer, older))
        #expect(stablePositiveFindingOrder(older, newer) == false)

        let uppercaseScope = try rankingFixtureDraft(
            baselineSequence: 1,
            comparisonSequence: 2,
            endpointPrefix: "scope-uppercase",
            scopeID: "scope-A"
        )
        let lowercaseScope = try rankingFixtureDraft(
            baselineSequence: 1,
            comparisonSequence: 2,
            endpointPrefix: "scope-lowercase",
            scopeID: "scope-a"
        )

        #expect(stablePositiveFindingOrder(uppercaseScope, lowercaseScope))
        #expect(stablePositiveFindingOrder(lowercaseScope, uppercaseScope) == false)
    }

    @Test("Catalog upgrades preserve measurement continuity and freeze both decisions")
    func freezesClassificationAcrossCatalogUpgrade() throws {
        let baselineDecision = try classifiedFindingDecision(
            catalogVersion: 1,
            ruleID: "cache-v1",
            ruleVersion: 3,
            category: .logsAndCaches
        )
        let comparisonDecision = try classifiedFindingDecision(
            catalogVersion: 2,
            ruleID: "developer-v2",
            ruleVersion: 7,
            category: .developerTools
        )
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            children: [
                .present(
                    subjectID: "classified",
                    path: "/Fixtures/Classified",
                    bytes: 10,
                    classification: baselineDecision
                ),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            children: [
                .present(
                    subjectID: "classified",
                    path: "/Fixtures/Classified",
                    bytes: 15,
                    classification: comparisonDecision
                ),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )
        let growth = try finding(
            comparisonEndpointID: "comparison-classified",
            in: result
        )

        #expect(growth.kind == .growth)
        #expect(growth.evidence.baselineClassificationDecision == baselineDecision)
        #expect(growth.evidence.comparisonClassificationDecision == comparisonDecision)
    }

    @Test("Monotonic sequence allows wall-clock rollback and preserves endpoint times")
    func supportsWallClockRollback() throws {
        let baseline = try makeFindingFrame(
            sequence: 10,
            endpointPrefix: "baseline",
            observedAt: 20_000,
            children: [
                .present(subjectID: "clock", path: "/Fixtures/Clock", bytes: 10),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 11,
            endpointPrefix: "comparison",
            observedAt: 10_000,
            children: [
                .present(subjectID: "clock", path: "/Fixtures/Clock", bytes: 11),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )
        let growth = try finding(comparisonEndpointID: "comparison-clock", in: result)

        #expect(growth.kind == .growth)
        #expect(growth.evidence.baselineTime.millisecondsSince1970 == 20_000)
        #expect(growth.evidence.comparisonTime.millisecondsSince1970 == 10_000)
    }

    @Test("Maximum signed-byte endpoints remain representable")
    func handlesIntegerBoundary() throws {
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            rootBytes: 0,
            children: [
                .present(subjectID: "maximum", path: "/Fixtures/Maximum", bytes: 0),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            rootBytes: Int64.max,
            children: [
                .present(
                    subjectID: "maximum",
                    path: "/Fixtures/Maximum",
                    bytes: Int64.max
                ),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )
        let maximum = try finding(
            comparisonEndpointID: "comparison-maximum",
            in: result
        )

        #expect(maximum.inclusiveDelta == .logical(bytes: Int64.max))
        #expect(maximum.rankingContribution == .logical(bytes: Int64.max))
        #expect(result.batch.rankedPositiveFindingKeys == [maximum.key])
    }

    @Test("Case and Unicode distinct paths plus input permutations yield identical output")
    func preservesBinaryPathIdentityAndPermutationDeterminism() throws {
        let baselineChildren: [FindingNodeFixture] = [
            .present(subjectID: "upper", path: "/Fixtures/Cache", bytes: 10),
            .present(subjectID: "lower", path: "/Fixtures/cache", bytes: 10),
            .present(subjectID: "composed", path: "/Fixtures/é", bytes: 10),
            .present(subjectID: "decomposed", path: "/Fixtures/e\u{301}", bytes: 10),
        ]
        let comparisonChildren: [FindingNodeFixture] = [
            .present(subjectID: "upper", path: "/Fixtures/Cache", bytes: 11),
            .present(subjectID: "lower", path: "/Fixtures/cache", bytes: 11),
            .present(subjectID: "composed", path: "/Fixtures/é", bytes: 11),
            .present(subjectID: "decomposed", path: "/Fixtures/e\u{301}", bytes: 11),
        ]

        let ordered = try HistoricalFindingGenerator().generate(
            baseline: makeFindingFrame(
                sequence: 1,
                endpointPrefix: "baseline",
                rootBytes: 100,
                children: baselineChildren
            ),
            comparison: makeFindingFrame(
                sequence: 2,
                endpointPrefix: "comparison",
                rootBytes: 104,
                children: comparisonChildren
            )
        )
        let reversed = try HistoricalFindingGenerator().generate(
            baseline: makeFindingFrame(
                sequence: 1,
                endpointPrefix: "baseline",
                rootBytes: 100,
                children: Array(baselineChildren.reversed())
            ),
            comparison: makeFindingFrame(
                sequence: 2,
                endpointPrefix: "comparison",
                rootBytes: 104,
                children: Array(comparisonChildren.reversed())
            )
        )

        #expect(ordered == reversed)
        #expect(Set(ordered.batch.findings.map(\.key)).count == ordered.batch.findings.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(ordered) == encoder.encode(reversed))
    }

    @Test("An explicit subtree appearance or disappearance is emitted once at its proven root")
    func collapsesDescendantsCoveredBySubtreeTransitions() throws {
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            children: [
                .absent(subjectID: "appeared", path: "/Fixtures/Appeared"),
                .present(
                    subjectID: "disappeared",
                    path: "/Fixtures/Disappeared",
                    bytes: 40
                ),
                .present(
                    subjectID: "disappeared-child",
                    parentSubjectID: "disappeared",
                    path: "/Fixtures/Disappeared/Child",
                    bytes: 15
                ),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            children: [
                .present(subjectID: "appeared", path: "/Fixtures/Appeared", bytes: 50),
                .present(
                    subjectID: "appeared-child",
                    parentSubjectID: "appeared",
                    path: "/Fixtures/Appeared/Child",
                    bytes: 20
                ),
                .absent(subjectID: "disappeared", path: "/Fixtures/Disappeared"),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )
        let appearance = try finding(
            comparisonEndpointID: "comparison-appeared",
            in: result
        )
        let disappearance = try finding(
            comparisonEndpointID: "comparison-disappeared",
            in: result
        )

        #expect(result.batch.findings.count == 2)
        #expect(appearance.kind == .appearance)
        #expect(appearance.inclusiveDelta == .logical(bytes: 50))
        #expect(appearance.rankingContribution == .logical(bytes: 50))
        #expect(disappearance.kind == .disappearance)
        #expect(disappearance.inclusiveDelta == .logical(bytes: -40))
        assertReasonCounts(
            result.suppressionSummary.collapses,
            equal: sortedReasonCounts([
                (.coveredByAncestorAppearance, 1),
                (.coveredByAncestorDisappearance, 1),
            ])
        )
    }

    @Test("Every source and destination parent corner must contain complete move proof")
    func rejectsIncompleteRelevantMoveParents() throws {
        let cases: [(String, RelevantParentProof, RelevantParentProof, RelevantParentProof, RelevantParentProof)] = [
            ("comparison source missing", .complete, .missing, .complete, .complete),
            ("baseline destination missing", .complete, .complete, .missing, .complete),
            ("baseline source partial", .partialMeasurement, .complete, .complete, .complete),
            ("comparison source partial", .complete, .partialMeasurement, .complete, .complete),
            ("baseline destination partial", .complete, .complete, .partialMeasurement, .complete),
            ("comparison destination partial", .complete, .complete, .complete, .partialMeasurement),
            ("baseline source enumeration incomplete", .incompleteChildren, .complete, .complete, .complete),
            ("comparison source enumeration incomplete", .complete, .incompleteChildren, .complete, .complete),
            ("baseline destination enumeration incomplete", .complete, .complete, .incompleteChildren, .complete),
            ("comparison destination enumeration incomplete", .complete, .complete, .complete, .incompleteChildren),
        ]

        for testCase in cases {
            let result = try generateReparentMoveCandidate(
                baselineSource: testCase.1,
                comparisonSource: testCase.2,
                baselineDestination: testCase.3,
                comparisonDestination: testCase.4
            )

            #expect(
                result.batch.findings.contains { $0.kind == .move } == false,
                Comment(rawValue: testCase.0)
            )
            #expect(
                result.suppressionSummary.findingSuppressions.first {
                    $0.reason == .moveParentEvidenceIncomplete
                }?.count == 1,
                Comment(rawValue: testCase.0)
            )
        }
    }

    @Test("Overflow while summing complete immediate children fails the whole projection")
    func rejectsChildSumOverflow() throws {
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            rootBytes: 0,
            children: [
                .present(subjectID: "first", path: "/Fixtures/First", bytes: Int64.max),
                .present(subjectID: "second", path: "/Fixtures/Second", bytes: Int64.max),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            rootBytes: 1,
            children: [
                .present(subjectID: "first", path: "/Fixtures/First", bytes: Int64.max),
                .present(subjectID: "second", path: "/Fixtures/Second", bytes: Int64.max),
            ]
        )

        #expect(throws: HistoricalFindingGenerationError.arithmeticOverflow) {
            try HistoricalFindingGenerator().generate(
                baseline: baseline,
                comparison: comparison
            )
        }
    }

    @Test("Overflow while subtracting child flow from inclusive delta fails the projection")
    func rejectsExclusiveSubtractionOverflow() throws {
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            rootBytes: 0,
            children: [
                .present(subjectID: "child", path: "/Fixtures/Child", bytes: 1),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            rootBytes: Int64.max,
            children: [
                .present(subjectID: "child", path: "/Fixtures/Child", bytes: 0),
            ]
        )

        #expect(throws: HistoricalFindingGenerationError.arithmeticOverflow) {
            try HistoricalFindingGenerator().generate(
                baseline: baseline,
                comparison: comparison
            )
        }
    }

    @Test("A descendant renamed inside a moved parent remains an independent move")
    func doesNotCollapseChangedAncestorRelativeSuffix() throws {
        let evidence = try uniqueStableEvidence(token: "relative-suffix-generation")
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            children: [
                .present(
                    subjectID: "parent",
                    path: "/Fixtures/Old",
                    bytes: 100,
                    locationID: "location-parent-old",
                    identityBasis: .stableFileSystemObject,
                    stableIdentityEvidence: evidence
                ),
                .present(
                    subjectID: "child",
                    parentSubjectID: "parent",
                    path: "/Fixtures/Old/Before",
                    bytes: 40,
                    locationID: "location-child-before",
                    identityBasis: .stableFileSystemObject,
                    stableIdentityEvidence: evidence
                ),
            ]
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            children: [
                .present(
                    subjectID: "parent",
                    path: "/Fixtures/New",
                    bytes: 100,
                    locationID: "location-parent-new",
                    identityBasis: .stableFileSystemObject,
                    stableIdentityEvidence: evidence
                ),
                .present(
                    subjectID: "child",
                    parentSubjectID: "parent",
                    path: "/Fixtures/New/After",
                    bytes: 40,
                    locationID: "location-child-after",
                    identityBasis: .stableFileSystemObject,
                    stableIdentityEvidence: evidence
                ),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )
        let moves = result.batch.findings.filter { $0.kind == .move }

        #expect(moves.count == 2)
        #expect(
            moves.contains {
                $0.evidence.comparisonEndpointID.rawValue == "comparison-child"
                    && $0.movementContext == nil
            }
        )
        #expect(result.suppressionSummary.collapses.isEmpty)
    }

    @Test("A move-up parent is resolved before a child that depends on its move proof")
    func resolvesDestinationParentMoveDependency() throws {
        let evidence = try uniqueStableEvidence(token: "move-up-generation")
        let baseline = try makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            children: moveUpDependencyFixtures(
                parentPath: "/Fixtures/Container/Nested/Parent",
                parentParentSubjectID: "nested",
                parentLocation: "location-parent-old",
                childPath: "/Fixtures/Source/Child",
                childParentSubjectID: "source",
                childLocation: "location-child-old",
                evidence: evidence
            )
        )
        let comparison = try makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            children: moveUpDependencyFixtures(
                parentPath: "/Fixtures/Parent",
                parentParentSubjectID: "root",
                parentLocation: "location-parent-new",
                childPath: "/Fixtures/Parent/Child",
                childParentSubjectID: "moving-parent",
                childLocation: "location-child-new",
                evidence: evidence
            )
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )
        let moves = result.batch.findings.filter { $0.kind == .move }

        #expect(moves.count == 2)
        #expect(
            Set(moves.map(\.evidence.comparisonEndpointID.rawValue)) == [
                "comparison-moving-parent",
                "comparison-moving-child",
            ]
        )
        #expect(
            result.suppressionSummary.findingSuppressions.contains {
                $0.reason == .moveParentEvidenceIncomplete
            } == false
        )
    }

    @Test("Every durable finding aggregate rejects unknown fields")
    func durableFindingTypesRejectUnknownFields() throws {
        let result = try makeCodableFindingResult()
        let draft = try #require(result.batch.findings.first)
        let reasonCount = try #require(
            result.suppressionSummary.rankingExclusions.first
        )

        try assertRejectsUnknownField(result)
        try assertRejectsUnknownField(result.batch)
        try assertRejectsUnknownField(draft)
        try assertRejectsUnknownField(draft.evidence)
        try assertRejectsUnknownField(reasonCount)
        try assertRejectsUnknownField(result.suppressionSummary)
    }

    @Test("Finding evidence and draft keys revalidate cross-field invariants when decoded")
    func durableDraftsRejectContradictoryEvidenceAndKeys() throws {
        let result = try makeCodableFindingResult()
        let draft = try #require(result.batch.findings.first)

        var reusedEndpointEvidence = try findingJSONObject(draft.evidence)
        reusedEndpointEvidence["comparisonEndpointID"] = reusedEndpointEvidence[
            "baselineEndpointID"
        ]
        try assertDecodingRejected(
            HistoricalFindingEvidence.self,
            object: reusedEndpointEvidence
        )

        var nonIncreasingEvidence = try findingJSONObject(draft.evidence)
        nonIncreasingEvidence["comparisonSequence"] = nonIncreasingEvidence[
            "baselineSequence"
        ]
        try assertDecodingRejected(
            HistoricalFindingEvidence.self,
            object: nonIncreasingEvidence
        )

        var mismatchedDraft = try findingJSONObject(draft)
        var mismatchedKey = try #require(
            mismatchedDraft["key"] as? [String: Any]
        )
        mismatchedKey["kind"] = HistoricalFindingKind.move.rawValue
        mismatchedDraft["key"] = mismatchedKey
        try assertDecodingRejected(
            HistoricalFindingDraft.self,
            object: mismatchedDraft
        )
    }

    @Test("Finding batches reject invalid limits and non-canonical or duplicate keys")
    func durableBatchRejectsInvalidOrderingAndKeys() throws {
        let result = try makeCodableFindingResult()
        let validBatch = try findingJSONObject(result.batch)
        let findings = try #require(validBatch["findings"] as? [[String: Any]])
        let rankedKeys = try #require(
            validBatch["rankedPositiveFindingKeys"] as? [[String: Any]]
        )
        #expect(findings.count >= 2)
        #expect(rankedKeys.count >= 2)

        for invalidLimit in [0, 101] {
            var invalidBatch = validBatch
            invalidBatch["positiveLimit"] = invalidLimit
            try assertDecodingRejected(
                HistoricalFindingBatch.self,
                object: invalidBatch
            )
        }

        var unorderedFindings = validBatch
        unorderedFindings["findings"] = Array(findings.reversed())
        try assertDecodingRejected(
            HistoricalFindingBatch.self,
            object: unorderedFindings
        )

        var duplicateFindings = validBatch
        duplicateFindings["findings"] = findings + [findings[0]]
        try assertDecodingRejected(
            HistoricalFindingBatch.self,
            object: duplicateFindings
        )

        var unorderedRankedKeys = validBatch
        unorderedRankedKeys["rankedPositiveFindingKeys"] = Array(rankedKeys.reversed())
        try assertDecodingRejected(
            HistoricalFindingBatch.self,
            object: unorderedRankedKeys
        )

        var duplicateRankedKeys = validBatch
        duplicateRankedKeys["rankedPositiveFindingKeys"] = [rankedKeys[0], rankedKeys[0]]
        try assertDecodingRejected(
            HistoricalFindingBatch.self,
            object: duplicateRankedKeys
        )
    }

    @Test("Reason counts and summaries reject non-positive or non-canonical durable values")
    func durableSuppressionSummaryRejectsInvalidCountsAndOrdering() throws {
        let result = try makeCodableFindingResult()
        let reasonCount = try #require(
            result.suppressionSummary.rankingExclusions.first
        )
        let validReasonCount = try findingJSONObject(reasonCount)

        for invalidCount in [0, -1] {
            var invalidReasonCount = validReasonCount
            invalidReasonCount["count"] = invalidCount
            try assertDecodingRejected(
                HistoricalFindingReasonCount.self,
                object: invalidReasonCount
            )
        }

        let validSummary = try findingJSONObject(result.suppressionSummary)
        let kindIneligible: [String: Any] = [
            "reason": HistoricalFindingReason.rankingKindIneligible.rawValue,
            "count": 1,
        ]
        let nonPositive: [String: Any] = [
            "reason": HistoricalFindingReason.rankingNonPositiveContribution.rawValue,
            "count": 1,
        ]

        var unorderedReasons = validSummary
        unorderedReasons["rankingExclusions"] = [nonPositive, kindIneligible]
        try assertDecodingRejected(
            HistoricalFindingSuppressionSummary.self,
            object: unorderedReasons
        )

        var duplicateReasons = validSummary
        duplicateReasons["rankingExclusions"] = [kindIneligible, kindIneligible]
        try assertDecodingRejected(
            HistoricalFindingSuppressionSummary.self,
            object: duplicateReasons
        )

        var negativeTruncation = validSummary
        negativeTruncation["truncatedPositiveCount"] = -1
        try assertDecodingRejected(
            HistoricalFindingSuppressionSummary.self,
            object: negativeTruncation
        )
    }

    @Test("Generation results reject a summary that contradicts its retained batch")
    func durableGenerationResultRejectsContradictoryTruncation() throws {
        let result = try makeCodableFindingResult()
        var invalidResult = try findingJSONObject(result)
        var invalidSummary = try #require(
            invalidResult["suppressionSummary"] as? [String: Any]
        )
        invalidSummary["truncatedPositiveCount"] = 99
        invalidResult["suppressionSummary"] = invalidSummary

        try assertDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: invalidResult
        )
    }

    @Test("Canonical finding output is byte-stable across a decode and re-encode")
    func canonicalFindingOutputRoundTripsByteForByte() throws {
        let result = try makeCodableFindingResult()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let firstEncoding = try encoder.encode(result)
        let decoded = try JSONDecoder().decode(
            HistoricalFindingGenerationResult.self,
            from: firstEncoding
        )
        let secondEncoding = try encoder.encode(decoded)

        #expect(decoded == result)
        #expect(secondEncoding == firstEncoding)
    }
}

private enum FindingFixtureState {
    case present(bytes: Int64, coverage: ObservationCoverage)
    case absent
    case unknown(ObservationUnavailabilityReason)
}

private enum RelevantParentProof {
    case complete
    case missing
    case partialMeasurement
    case incompleteChildren
}

private struct FindingNodeFixture {
    let endpointID: String?
    let subjectID: String
    let parentSubjectID: String
    let path: String
    let displayName: String
    let locationID: String
    let identityBasis: ObservationSubjectIdentityBasis
    let state: FindingFixtureState
    let directChildrenCoverage: ObservationCoverage
    let classification: VersionedAttributionDecision?
    let stableIdentityEvidence: HistoricalFindingStableIdentityEvidence?

    static func present(
        subjectID: String,
        parentSubjectID: String = "root",
        path: String,
        bytes: Int64,
        endpointID: String? = nil,
        locationID: String? = nil,
        identityBasis: ObservationSubjectIdentityBasis = .normalizedPath,
        coverage: ObservationCoverage = .complete,
        directChildrenCoverage: ObservationCoverage = .complete,
        classification: VersionedAttributionDecision? = nil,
        stableIdentityEvidence: HistoricalFindingStableIdentityEvidence? = nil
    ) -> Self {
        Self(
            endpointID: endpointID,
            subjectID: subjectID,
            parentSubjectID: parentSubjectID,
            path: path,
            displayName: String(path.split(separator: "/").last ?? "Fixtures"),
            locationID: locationID ?? "location-\(subjectID)",
            identityBasis: identityBasis,
            state: .present(bytes: bytes, coverage: coverage),
            directChildrenCoverage: directChildrenCoverage,
            classification: classification,
            stableIdentityEvidence: stableIdentityEvidence
        )
    }

    static func absent(
        subjectID: String,
        parentSubjectID: String = "root",
        path: String,
        endpointID: String? = nil,
        locationID: String? = nil
    ) -> Self {
        Self(
            endpointID: endpointID,
            subjectID: subjectID,
            parentSubjectID: parentSubjectID,
            path: path,
            displayName: String(path.split(separator: "/").last ?? "Fixtures"),
            locationID: locationID ?? "location-\(subjectID)",
            identityBasis: .normalizedPath,
            state: .absent,
            directChildrenCoverage: .unknown,
            classification: nil,
            stableIdentityEvidence: nil
        )
    }

    static func unknown(
        subjectID: String,
        parentSubjectID: String = "root",
        path: String,
        reason: ObservationUnavailabilityReason,
        endpointID: String? = nil,
        locationID: String? = nil
    ) -> Self {
        Self(
            endpointID: endpointID,
            subjectID: subjectID,
            parentSubjectID: parentSubjectID,
            path: path,
            displayName: String(path.split(separator: "/").last ?? "Fixtures"),
            locationID: locationID ?? "location-\(subjectID)",
            identityBasis: .normalizedPath,
            state: .unknown(reason),
            directChildrenCoverage: .unknown,
            classification: nil,
            stableIdentityEvidence: nil
        )
    }
}

private func makeFindingFrame(
    sequence: Int64,
    endpointPrefix: String,
    rootBytes: Int64 = 1_000,
    rootDirectChildrenCoverage: ObservationCoverage = .complete,
    rootLocationID: String = "location-root",
    rootIdentityBasis: ObservationSubjectIdentityBasis = .normalizedPath,
    rootStableIdentityEvidence: HistoricalFindingStableIdentityEvidence? = nil,
    scopeID: String = "scope-a",
    volumeID: String = "volume-a",
    mountGenerationID: String = "mount-a",
    coverageEpochID: String = "coverage-a",
    observedAt: Int64? = nil,
    children: [FindingNodeFixture] = []
) throws -> HistoricalFindingObservationFrame {
    let decision = try defaultFindingDecision()
    let root = try makeFindingNode(
        endpointID: "\(endpointPrefix)-root",
        subjectID: "root",
        parentSubjectID: nil,
        path: "/Fixtures",
        displayName: "Fixtures",
        locationID: rootLocationID,
        identityBasis: rootIdentityBasis,
        state: .present(bytes: rootBytes, coverage: .complete),
        directChildrenCoverage: rootDirectChildrenCoverage,
        classification: decision,
        stableIdentityEvidence: rootStableIdentityEvidence,
        sequence: sequence,
        scopeID: scopeID,
        volumeID: volumeID,
        mountGenerationID: mountGenerationID,
        coverageEpochID: coverageEpochID,
        observedAt: observedAt ?? sequence * 1_000,
        endpointPrefix: endpointPrefix
    )
    let childNodes = try children.map { fixture in
        try makeFindingNode(
            endpointID: fixture.endpointID ?? "\(endpointPrefix)-\(fixture.subjectID)",
            subjectID: fixture.subjectID,
            parentSubjectID: fixture.parentSubjectID,
            path: fixture.path,
            displayName: fixture.displayName,
            locationID: fixture.locationID,
            identityBasis: fixture.identityBasis,
            state: fixture.state,
            directChildrenCoverage: fixture.directChildrenCoverage,
            classification: fixture.classification,
            stableIdentityEvidence: fixture.stableIdentityEvidence,
            sequence: sequence,
            scopeID: scopeID,
            volumeID: volumeID,
            mountGenerationID: mountGenerationID,
            coverageEpochID: coverageEpochID,
            observedAt: observedAt ?? sequence * 1_000,
            endpointPrefix: endpointPrefix
        )
    }

    return try HistoricalFindingObservationFrame(
        rootSubjectID: SubjectID("root"),
        rootPath: "/Fixtures",
        nodes: [root] + childNodes
    )
}

private func makeFindingNode(
    endpointID: String,
    subjectID: String,
    parentSubjectID: String?,
    path: String,
    displayName: String,
    locationID: String,
    identityBasis: ObservationSubjectIdentityBasis,
    state: FindingFixtureState,
    directChildrenCoverage: ObservationCoverage,
    classification: VersionedAttributionDecision?,
    stableIdentityEvidence: HistoricalFindingStableIdentityEvidence?,
    sequence: Int64,
    scopeID: String,
    volumeID: String,
    mountGenerationID: String,
    coverageEpochID: String,
    observedAt: Int64,
    endpointPrefix: String
) throws -> HistoricalFindingNode {
    let endpointState: ObservationEndpointState
    let resolvedClassification: VersionedAttributionDecision?
    switch state {
    case .present(let bytes, let coverage):
        endpointState = .present(bytes: try ByteCount(bytes), coverage: coverage)
        resolvedClassification = try classification ?? defaultFindingDecision()
    case .absent:
        let parent = try #require(parentSubjectID)
        endpointState = .absent(
            ParentAbsenceReference(
                parentEndpointID: try ObservationEndpointID("\(endpointPrefix)-\(parent)"),
                parentSubjectID: try SubjectID(parent)
            )
        )
        resolvedClassification = nil
    case .unknown(let reason):
        endpointState = .unknown(reason)
        resolvedClassification = nil
    }

    let endpoint = try ObservationEndpoint(
        id: ObservationEndpointID(endpointID),
        scopeID: ScopeID(scopeID),
        volumeID: ObservationVolumeID(volumeID),
        mountGenerationID: ObservationMountGenerationID(mountGenerationID),
        coverageEpochID: ObservationCoverageEpochID(coverageEpochID),
        subjectID: SubjectID(subjectID),
        identityBasis: identityBasis,
        locationID: ObservationLocationID(locationID),
        metric: .logical,
        pathSemanticsVersion: ObservationSemanticsVersion(1),
        measurementSemanticsVersion: ObservationSemanticsVersion(1),
        sequence: ObservationCommitSequence(sequence),
        observedAt: ObservationInstant(millisecondsSince1970: observedAt),
        state: endpointState
    )

    return try HistoricalFindingNode(
        endpoint: endpoint,
        parentSubjectID: try parentSubjectID.map { try SubjectID($0) },
        path: path,
        displayName: displayName,
        directChildrenCoverage: directChildrenCoverage,
        classification: resolvedClassification,
        stableIdentityEvidence: stableIdentityEvidence
    )
}

private func defaultFindingDecision(
    catalogVersion: Int = 1
) throws -> VersionedAttributionDecision {
    try VersionedAttributionDecision(
        catalogVersion: AttributionCatalogVersion(catalogVersion),
        result: .unknown(.noMatchingRule)
    )
}

private func classifiedFindingDecision(
    catalogVersion: Int,
    ruleID: String,
    ruleVersion: Int,
    category: StorageAttributionCategory
) throws -> VersionedAttributionDecision {
    let attribution = try StorageAttribution(
        category: category,
        confidence: .high,
        ruleID: AttributionRuleID(ruleID),
        ruleVersion: AttributionRuleVersion(ruleVersion),
        evidenceCode: AttributionEvidenceCode("fixture-match")
    )
    return try VersionedAttributionDecision(
        catalogVersion: AttributionCatalogVersion(catalogVersion),
        result: .classified(attribution)
    )
}

private func uniqueStableEvidence(
    token: String
) throws -> HistoricalFindingStableIdentityEvidence {
    try HistoricalFindingStableIdentityEvidence(
        reuseGuard: .generationToken(token),
        nodeKind: .directory,
        linkStatus: .unique
    )
}

private func movedTreeFixtures(
    parentPath: String,
    parentLocation: String,
    parentBytes: Int64,
    childBytes: Int64,
    childLocation: String,
    evidence: HistoricalFindingStableIdentityEvidence
) -> [FindingNodeFixture] {
    [
        .present(
            subjectID: "parent",
            path: parentPath,
            bytes: parentBytes,
            locationID: parentLocation,
            identityBasis: .stableFileSystemObject,
            stableIdentityEvidence: evidence
        ),
        .present(
            subjectID: "child",
            parentSubjectID: "parent",
            path: "\(parentPath)/Child",
            bytes: childBytes,
            locationID: childLocation,
            identityBasis: .stableFileSystemObject,
            stableIdentityEvidence: evidence
        ),
    ]
}

private func generateMoveCandidate(
    identityBasis: ObservationSubjectIdentityBasis = .stableFileSystemObject,
    baselineEvidence: HistoricalFindingStableIdentityEvidence?,
    comparisonEvidence: HistoricalFindingStableIdentityEvidence?,
    parentCoverage: ObservationCoverage = .complete,
    comparisonMountGenerationID: String = "mount-a"
) throws -> HistoricalFindingGenerationResult {
    let baseline = try makeFindingFrame(
        sequence: 1,
        endpointPrefix: "baseline",
        rootDirectChildrenCoverage: parentCoverage,
        children: [
            .present(
                subjectID: "candidate",
                path: "/Fixtures/Old",
                bytes: 10,
                locationID: "location-old",
                identityBasis: identityBasis,
                stableIdentityEvidence: baselineEvidence
            ),
        ]
    )
    let comparison = try makeFindingFrame(
        sequence: 2,
        endpointPrefix: "comparison",
        rootDirectChildrenCoverage: parentCoverage,
        mountGenerationID: comparisonMountGenerationID,
        children: [
            .present(
                subjectID: "candidate",
                path: "/Fixtures/New",
                bytes: 10,
                locationID: "location-new",
                identityBasis: identityBasis,
                stableIdentityEvidence: comparisonEvidence
            ),
        ]
    )

    return try HistoricalFindingGenerator().generate(
        baseline: baseline,
        comparison: comparison
    )
}

private func generateReparentMoveCandidate(
    baselineSource: RelevantParentProof,
    comparisonSource: RelevantParentProof,
    baselineDestination: RelevantParentProof,
    comparisonDestination: RelevantParentProof
) throws -> HistoricalFindingGenerationResult {
    let evidence = try uniqueStableEvidence(token: "reparent-generation")
    var baselineChildren = relevantParentFixtures(
        subjectID: "source-parent",
        path: "/Fixtures/Source",
        proof: baselineSource
    ) + relevantParentFixtures(
        subjectID: "destination-parent",
        path: "/Fixtures/Destination",
        proof: baselineDestination
    )
    baselineChildren.append(
        .present(
            subjectID: "moving-child",
            parentSubjectID: "source-parent",
            path: "/Fixtures/Source/Child",
            bytes: 10,
            locationID: "location-child-old",
            identityBasis: .stableFileSystemObject,
            stableIdentityEvidence: evidence
        )
    )

    var comparisonChildren = relevantParentFixtures(
        subjectID: "source-parent",
        path: "/Fixtures/Source",
        proof: comparisonSource
    ) + relevantParentFixtures(
        subjectID: "destination-parent",
        path: "/Fixtures/Destination",
        proof: comparisonDestination
    )
    comparisonChildren.append(
        .present(
            subjectID: "moving-child",
            parentSubjectID: "destination-parent",
            path: "/Fixtures/Destination/Child",
            bytes: 10,
            locationID: "location-child-new",
            identityBasis: .stableFileSystemObject,
            stableIdentityEvidence: evidence
        )
    )

    return try HistoricalFindingGenerator().generate(
        baseline: makeFindingFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            children: baselineChildren
        ),
        comparison: makeFindingFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            children: comparisonChildren
        )
    )
}

private func relevantParentFixtures(
    subjectID: String,
    path: String,
    proof: RelevantParentProof
) -> [FindingNodeFixture] {
    switch proof {
    case .complete:
        [
            .present(
                subjectID: subjectID,
                path: path,
                bytes: 100,
                locationID: "location-\(subjectID)"
            ),
        ]
    case .missing:
        []
    case .partialMeasurement:
        [
            .present(
                subjectID: subjectID,
                path: path,
                bytes: 100,
                locationID: "location-\(subjectID)",
                coverage: .partial
            ),
        ]
    case .incompleteChildren:
        [
            .present(
                subjectID: subjectID,
                path: path,
                bytes: 100,
                locationID: "location-\(subjectID)",
                directChildrenCoverage: .partial
            ),
        ]
    }
}

private func moveUpDependencyFixtures(
    parentPath: String,
    parentParentSubjectID: String,
    parentLocation: String,
    childPath: String,
    childParentSubjectID: String,
    childLocation: String,
    evidence: HistoricalFindingStableIdentityEvidence
) -> [FindingNodeFixture] {
    [
        .present(
            subjectID: "container",
            path: "/Fixtures/Container",
            bytes: 200
        ),
        .present(
            subjectID: "nested",
            parentSubjectID: "container",
            path: "/Fixtures/Container/Nested",
            bytes: 150
        ),
        .present(
            subjectID: "source",
            path: "/Fixtures/Source",
            bytes: 80
        ),
        .present(
            subjectID: "moving-parent",
            parentSubjectID: parentParentSubjectID,
            path: parentPath,
            bytes: 100,
            locationID: parentLocation,
            identityBasis: .stableFileSystemObject,
            stableIdentityEvidence: evidence
        ),
        .present(
            subjectID: "moving-child",
            parentSubjectID: childParentSubjectID,
            path: childPath,
            bytes: 40,
            locationID: childLocation,
            identityBasis: .stableFileSystemObject,
            stableIdentityEvidence: evidence
        ),
    ]
}

private func finding(
    comparisonEndpointID: String,
    in result: HistoricalFindingGenerationResult
) throws -> HistoricalFindingDraft {
    try #require(
        result.batch.findings.first {
            $0.evidence.comparisonEndpointID.rawValue == comparisonEndpointID
        }
    )
}

private func rankingFixtureDraft(
    baselineSequence: Int64,
    comparisonSequence: Int64,
    endpointPrefix: String,
    scopeID: String
) throws -> HistoricalFindingDraft {
    let baseline = try makeFindingFrame(
        sequence: baselineSequence,
        endpointPrefix: "\(endpointPrefix)-baseline",
        rootBytes: 100,
        scopeID: scopeID,
        children: [
            .present(subjectID: "ranked", path: "/Fixtures/Ranked", bytes: 10),
        ]
    )
    let comparison = try makeFindingFrame(
        sequence: comparisonSequence,
        endpointPrefix: "\(endpointPrefix)-comparison",
        rootBytes: 100,
        scopeID: scopeID,
        children: [
            .present(subjectID: "ranked", path: "/Fixtures/Ranked", bytes: 15),
        ]
    )
    return try #require(
        HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        ).batch.findings.only
    )
}

private func assertReasonCounts(
    _ actual: [HistoricalFindingReasonCount],
    equal expected: [(HistoricalFindingReason, Int)],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(actual.map(\.reason) == expected.map(\.0), sourceLocation: sourceLocation)
    #expect(actual.map(\.count) == expected.map(\.1), sourceLocation: sourceLocation)
}

private func sortedReasonCounts(
    _ values: [(HistoricalFindingReason, Int)]
) -> [(HistoricalFindingReason, Int)] {
    values.sorted {
        $0.0.rawValue.utf8.lexicographicallyPrecedes($1.0.rawValue.utf8)
    }
}

private func makeCodableFindingResult() throws -> HistoricalFindingGenerationResult {
    let baseline = try makeFindingFrame(
        sequence: 1,
        endpointPrefix: "codable-baseline",
        rootBytes: 100,
        children: [
            .present(subjectID: "growth-a", path: "/Fixtures/GrowthA", bytes: 10),
            .present(subjectID: "growth-b", path: "/Fixtures/GrowthB", bytes: 10),
            .present(subjectID: "decrease", path: "/Fixtures/Decrease", bytes: 10),
        ]
    )
    let comparison = try makeFindingFrame(
        sequence: 2,
        endpointPrefix: "codable-comparison",
        rootBytes: 100,
        children: [
            .present(subjectID: "growth-a", path: "/Fixtures/GrowthA", bytes: 12),
            .present(subjectID: "growth-b", path: "/Fixtures/GrowthB", bytes: 11),
            .present(subjectID: "decrease", path: "/Fixtures/Decrease", bytes: 9),
        ]
    )
    return try HistoricalFindingGenerator().generate(
        baseline: baseline,
        comparison: comparison
    )
}

private func findingJSONObject<Value: Encodable>(
    _ value: Value
) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
}

private func assertRejectsUnknownField<Value: Codable>(
    _ value: Value,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    var object = try findingJSONObject(value)
    object["unexpected"] = true
    try assertDecodingRejected(
        Value.self,
        object: object,
        sourceLocation: sourceLocation
    )
}

private func assertDecodingRejected<Value: Decodable>(
    _ type: Value.Type,
    object: [String: Any],
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    )
    #expect(throws: DecodingError.self, sourceLocation: sourceLocation) {
        try JSONDecoder().decode(type, from: data)
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
