import Foundation
import SpaceTraceApplication
import SpaceTraceAttribution
import SpaceTraceDomain
import Testing

struct HistoricalFindingDurabilityRegressionTests {
    @Test("Finding nodes reject explicit null for canonical optional fields")
    func findingNodesRejectExplicitNullOptionals() throws {
        let presentFrame = try regressionFrame(
            sequence: 1,
            endpointPrefix: "present"
        )
        let presentRoot = try #require(
            presentFrame.nodes.first { $0.endpoint.subjectID.rawValue == "root" }
        )
        let presentObject = try regressionJSONObject(presentRoot)
        for optionalField in ["parentSubjectID", "stableIdentityEvidence"] {
            var explicitNull = presentObject
            explicitNull[optionalField] = NSNull()
            try expectRegressionDecodingRejected(
                HistoricalFindingNode.self,
                object: explicitNull,
                because: "Canonical nil field \(optionalField) must be absent, not null."
            )
        }

        let absentFrame = try regressionFrame(
            sequence: 1,
            endpointPrefix: "absent",
            children: [
                RegressionNodeFixture(
                    subjectID: "missing",
                    parentSubjectID: "root",
                    path: "/Fixtures/Missing",
                    locationID: "location-missing",
                    state: .absent,
                    identityBasis: .normalizedPath,
                    stableIdentityEvidence: nil
                ),
            ]
        )
        let absentNode = try #require(
            absentFrame.nodes.first { $0.endpoint.subjectID.rawValue == "missing" }
        )
        var explicitNullClassification = try regressionJSONObject(absentNode)
        explicitNullClassification["classification"] = NSNull()
        try expectRegressionDecodingRejected(
            HistoricalFindingNode.self,
            object: explicitNullClassification,
            because: "Canonical absent-node classification must be omitted, not null."
        )
    }

    @Test("Observation frame decoding rejects a non-canonical node array")
    func frameDecodingRejectsNonCanonicalNodeOrder() throws {
        let frame = try regressionFrame(
            sequence: 1,
            endpointPrefix: "canonical",
            children: [
                regressionPresentFixture(
                    subject: "child",
                    path: "/Fixtures/Child",
                    bytes: 10
                ),
            ]
        )
        var object = try regressionJSONObject(frame)
        let nodes = try #require(object["nodes"] as? [[String: Any]])
        #expect(nodes.count == 2)
        object["nodes"] = Array(nodes.reversed())

        try expectRegressionDecodingRejected(
            HistoricalFindingObservationFrame.self,
            object: object,
            because: "A durable frame decoder must not silently reorder its node ledger."
        )
    }

    @Test(
        "Non-increasing frames produce one strict frame suppression without findings",
        arguments: [
            NonIncreasingSequenceCase(baseline: 1, comparison: 1),
            NonIncreasingSequenceCase(baseline: 2, comparison: 1),
        ]
    )
    func nonIncreasingFramesProduceStrictSuppression(
        testCase: NonIncreasingSequenceCase
    ) throws {
        let result = try HistoricalFindingGenerator().generate(
            baseline: regressionFrame(
                sequence: testCase.baseline,
                endpointPrefix: "baseline"
            ),
            comparison: regressionFrame(
                sequence: testCase.comparison,
                endpointPrefix: "comparison"
            )
        )

        #expect(result.batch.baselineSequence.rawValue == testCase.baseline)
        #expect(result.batch.comparisonSequence.rawValue == testCase.comparison)
        #expect(result.batch.algorithmVersion.rawValue == 1)
        #expect(result.batch.rankingPolicyVersion.rawValue == 1)
        #expect(result.batch.positiveLimit == 10)
        #expect(result.batch.findings.isEmpty)
        #expect(result.batch.rankedPositiveFindingKeys.isEmpty)
        try expectStrictNonIncreasingSummary(result.suppressionSummary)
    }

    @Test("Durable batches accept only the released finding and ranking versions")
    func batchRejectsUnsupportedVersions() throws {
        let result = try unchangedRegressionResult()
        let validBatch = try regressionJSONObject(result.batch)

        for versionField in ["algorithmVersion", "rankingPolicyVersion"] {
            var unsupported = validBatch
            unsupported[versionField] = 2

            try expectRegressionDecodingRejected(
                HistoricalFindingBatch.self,
                object: unsupported,
                because: "A durable batch with \(versionField)=2 must not be interpreted as v1."
            )
        }
    }

    @Test("Standalone durable finding values reject unsupported semantic versions")
    func standaloneFindingValuesRejectUnsupportedVersions() throws {
        let result = try twoGrowthRegressionResult()
        let draft = try #require(result.batch.findings.first)

        var unsupportedKey = try regressionJSONObject(draft.key)
        unsupportedKey["algorithmVersion"] = 2
        unsupportedKey["rankingPolicyVersion"] = 2
        try expectRegressionDecodingRejected(
            HistoricalFindingKey.self,
            object: unsupportedKey,
            because: "A v1 decoder cannot reinterpret a future finding key."
        )

        var unsupportedEvidence = try regressionJSONObject(draft.evidence)
        unsupportedEvidence["algorithmVersion"] = 2
        unsupportedEvidence["rankingPolicyVersion"] = 2
        try expectRegressionDecodingRejected(
            HistoricalFindingEvidence.self,
            object: unsupportedEvidence,
            because: "A v1 decoder cannot reinterpret future finding evidence."
        )

        var unsupportedDraft = try regressionJSONObject(draft)
        var draftKey = try #require(unsupportedDraft["key"] as? [String: Any])
        draftKey["algorithmVersion"] = 2
        draftKey["rankingPolicyVersion"] = 2
        unsupportedDraft["key"] = draftKey
        var draftEvidence = try #require(
            unsupportedDraft["evidence"] as? [String: Any]
        )
        draftEvidence["algorithmVersion"] = 2
        draftEvidence["rankingPolicyVersion"] = 2
        unsupportedDraft["evidence"] = draftEvidence
        try expectRegressionDecodingRejected(
            HistoricalFindingDraft.self,
            object: unsupportedDraft,
            because: "A self-consistent future draft still requires an explicit decoder."
        )
    }

    @Test("Every finding in one batch must retain one measurement context")
    func batchRejectsMixedFindingContexts() throws {
        let result = try twoGrowthRegressionResult()
        let validBatch = try regressionJSONObject(result.batch)
        let validFindings = try #require(validBatch["findings"] as? [[String: Any]])
        #expect(validFindings.count == 2)

        let scalarMutations: [(field: String, value: String)] = [
            ("scopeID", "scope-b"),
            ("volumeID", "volume-b"),
            ("mountGenerationID", "mount-b"),
            ("coverageEpochID", "coverage-b"),
        ]
        for mutation in scalarMutations {
            var findings = validFindings
            var second = findings[1]
            var evidence = try #require(second["evidence"] as? [String: Any])
            evidence[mutation.field] = mutation.value
            second["evidence"] = evidence
            findings[1] = second

            var mixedBatch = validBatch
            mixedBatch["findings"] = findings
            try expectRegressionDecodingRejected(
                HistoricalFindingBatch.self,
                object: mixedBatch,
                because: "One batch cannot mix \(mutation.field) values."
            )
        }

        var metricFindings = validFindings
        var second = metricFindings[1]
        var evidence = try #require(second["evidence"] as? [String: Any])
        evidence["metric"] = "allocated"
        second["evidence"] = evidence
        var inclusiveDelta = try #require(second["inclusiveDelta"] as? [String: Any])
        inclusiveDelta["kind"] = "allocated"
        second["inclusiveDelta"] = inclusiveDelta
        var rankingContribution = try #require(
            second["rankingContribution"] as? [String: Any]
        )
        rankingContribution["kind"] = "allocated"
        second["rankingContribution"] = rankingContribution
        metricFindings[1] = second

        var mixedMetricBatch = validBatch
        mixedMetricBatch["findings"] = metricFindings
        try expectRegressionDecodingRejected(
            HistoricalFindingBatch.self,
            object: mixedMetricBatch,
            because: "One batch cannot mix logical and allocated findings."
        )
    }

    @Test("Inherited movement must name a true two-frame ancestor with one relative suffix")
    func inheritedMovementRevalidatesAncestryAndSuffix() throws {
        let result = try inheritedMovementRegressionResult()
        let validBatch = try regressionJSONObject(result.batch)
        let validFindings = try #require(validBatch["findings"] as? [[String: Any]])
        let inheritedIndex = try #require(
            validFindings.firstIndex { $0["movementContext"] != nil }
        )

        var baselineOutside = validFindings
        var outsideDraft = baselineOutside[inheritedIndex]
        var outsideEvidence = try #require(outsideDraft["evidence"] as? [String: Any])
        outsideEvidence["baselinePath"] = "/Fixtures/Else/Child"
        outsideDraft["evidence"] = outsideEvidence
        baselineOutside[inheritedIndex] = outsideDraft
        var baselineOutsideBatch = validBatch
        baselineOutsideBatch["findings"] = baselineOutside
        try expectRegressionDecodingRejected(
            HistoricalFindingBatch.self,
            object: baselineOutsideBatch,
            because: "The referenced move is not an ancestor on the baseline side."
        )

        var mismatchedSuffix = validFindings
        var suffixDraft = mismatchedSuffix[inheritedIndex]
        var suffixEvidence = try #require(suffixDraft["evidence"] as? [String: Any])
        suffixEvidence["comparisonPath"] = "/Fixtures/New/Renamed"
        suffixDraft["evidence"] = suffixEvidence
        mismatchedSuffix[inheritedIndex] = suffixDraft
        var mismatchedSuffixBatch = validBatch
        mismatchedSuffixBatch["findings"] = mismatchedSuffix
        try expectRegressionDecodingRejected(
            HistoricalFindingBatch.self,
            object: mismatchedSuffixBatch,
            because: "An inherited move cannot change its ancestor-relative suffix."
        )
    }

    @Test("Absence-parent endpoint identifiers participate in cross-frame disjointness")
    func absenceParentEndpointIDsCannotCrossFrameBoundary() throws {
        let appearanceResult = try appearanceRegressionResult()
        var batch = try regressionJSONObject(appearanceResult.batch)
        var findings = try #require(batch["findings"] as? [[String: Any]])
        #expect(findings.count == 1)
        var appearance = findings[0]
        var evidence = try #require(appearance["evidence"] as? [String: Any])
        var absenceReference = try #require(
            evidence["baselineAbsenceReference"] as? [String: Any]
        )
        absenceReference["parentEndpointID"] = "comparison-root"
        evidence["baselineAbsenceReference"] = absenceReference
        appearance["evidence"] = evidence
        findings[0] = appearance
        batch["findings"] = findings

        try expectRegressionDecodingRejected(
            HistoricalFindingBatch.self,
            object: batch,
            because: "Baseline absence evidence cannot reuse a comparison-frame endpoint ID."
        )

        let disappearanceResult = try disappearanceRegressionResult()
        batch = try regressionJSONObject(disappearanceResult.batch)
        findings = try #require(batch["findings"] as? [[String: Any]])
        #expect(findings.count == 1)
        var disappearance = findings[0]
        evidence = try #require(disappearance["evidence"] as? [String: Any])
        absenceReference = try #require(
            evidence["comparisonAbsenceReference"] as? [String: Any]
        )
        absenceReference["parentEndpointID"] = "baseline-root"
        evidence["comparisonAbsenceReference"] = absenceReference
        disappearance["evidence"] = evidence
        findings[0] = disappearance
        batch["findings"] = findings

        try expectRegressionDecodingRejected(
            HistoricalFindingBatch.self,
            object: batch,
            because: "Comparison absence evidence cannot reuse a baseline-frame endpoint ID."
        )
    }

    @Test("A durable non-increasing result accepts only its strict suppression shape")
    func nonIncreasingResultRequiresStrictSuppressionShape() throws {
        let canonical = try canonicalNonIncreasingResultObject()
        let decoded = try JSONDecoder().decode(
            HistoricalFindingGenerationResult.self,
            from: regressionJSONData(canonical)
        )
        #expect(decoded.batch.baselineSequence == decoded.batch.comparisonSequence)
        #expect(decoded.batch.findings.isEmpty)
        #expect(decoded.batch.rankedPositiveFindingKeys.isEmpty)
        try expectStrictNonIncreasingSummary(decoded.suppressionSummary)

        try expectRegressionDecodingRejected(
            HistoricalFindingBatch.self,
            object: regressionBatch(from: canonical),
            because: "Only the complete result envelope can justify a non-increasing empty batch."
        )

        var missingSuppression = canonical
        var summary = try regressionSummary(from: missingSuppression)
        summary["findingSuppressions"] = []
        missingSuppression["suppressionSummary"] = summary
        try expectRegressionDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: missingSuppression,
            because: "A non-increasing batch must explain its frame suppression."
        )

        var wrongSuppression = canonical
        summary = try regressionSummary(from: wrongSuppression)
        summary["findingSuppressions"] = [[
            "reason": HistoricalFindingReason.endpointScopeMismatch.rawValue,
            "count": 1,
        ]]
        wrongSuppression["suppressionSummary"] = summary
        try expectRegressionDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: wrongSuppression,
            because: "A rejected frame cannot be represented by an endpoint-level reason."
        )

        var multipliedSuppression = canonical
        summary = try regressionSummary(from: multipliedSuppression)
        summary["findingSuppressions"] = [[
            "reason": HistoricalFindingReason.frameNonIncreasingSequence.rawValue,
            "count": 2,
        ]]
        multipliedSuppression["suppressionSummary"] = summary
        try expectRegressionDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: multipliedSuppression,
            because: "A single frame rejection must be counted exactly once."
        )

        var extraSuppression = canonical
        summary = try regressionSummary(from: extraSuppression)
        summary["findingSuppressions"] = [
            [
                "reason": HistoricalFindingReason.frameMetricMismatch.rawValue,
                "count": 1,
            ],
            [
                "reason": HistoricalFindingReason.frameNonIncreasingSequence.rawValue,
                "count": 1,
            ],
        ]
        extraSuppression["suppressionSummary"] = summary
        try expectRegressionDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: extraSuppression,
            because: "A non-increasing batch cannot carry a second frame suppression."
        )

        var rankingExclusion = canonical
        summary = try regressionSummary(from: rankingExclusion)
        summary["rankingExclusions"] = [[
            "reason": HistoricalFindingReason.rankingKindIneligible.rawValue,
            "count": 1,
        ]]
        rankingExclusion["suppressionSummary"] = summary
        try expectRegressionDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: rankingExclusion,
            because: "No finding exists to justify a ranking exclusion."
        )

        var collapse = canonical
        summary = try regressionSummary(from: collapse)
        summary["collapses"] = [[
            "reason": HistoricalFindingReason.collapsedImplicitDescendantMove.rawValue,
            "count": 1,
        ]]
        collapse["suppressionSummary"] = summary
        try expectRegressionDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: collapse,
            because: "No finding exists to justify a collapse."
        )

        var truncation = canonical
        summary = try regressionSummary(from: truncation)
        summary["truncatedPositiveCount"] = 1
        truncation["suppressionSummary"] = summary
        try expectRegressionDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: truncation,
            because: "No eligible finding exists to justify truncation."
        )

        let growth = try twoGrowthRegressionResult()
        let growthBatch = try regressionJSONObject(growth.batch)
        let growthFindings = try #require(growthBatch["findings"] as? [[String: Any]])
        let growthRanks = try #require(
            growthBatch["rankedPositiveFindingKeys"] as? [[String: Any]]
        )

        var retainedFinding = canonical
        var nonIncreasingBatch = try regressionBatch(from: retainedFinding)
        nonIncreasingBatch["findings"] = [growthFindings[0]]
        retainedFinding["batch"] = nonIncreasingBatch
        try expectRegressionDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: retainedFinding,
            because: "A non-increasing frame cannot retain a finding."
        )

        var retainedRank = canonical
        nonIncreasingBatch = try regressionBatch(from: retainedRank)
        nonIncreasingBatch["rankedPositiveFindingKeys"] = [growthRanks[0]]
        retainedRank["batch"] = nonIncreasingBatch
        try expectRegressionDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: retainedRank,
            because: "A non-increasing frame cannot retain a ranking key."
        )
    }

    @Test("An empty increasing batch cannot claim impossible collapses")
    func emptyIncreasingBatchRejectsImpossibleCollapseSummary() throws {
        var object = try regressionJSONObject(unchangedRegressionResult())
        var summary = try regressionSummary(from: object)
        summary["collapses"] = [[
            "reason": HistoricalFindingReason.collapsedImplicitDescendantMove.rawValue,
            "count": 1,
        ]]
        object["suppressionSummary"] = summary

        try expectRegressionDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: object,
            because: "A collapse requires a retained causal ancestor finding."
        )
    }

    @Test("A frame-level suppression always retains the strict early-return shape")
    func frameSuppressionRejectsRetainedFindingsAndMixedReasons() throws {
        var object = try regressionJSONObject(twoGrowthRegressionResult())
        var summary = try regressionSummary(from: object)
        summary["findingSuppressions"] = [[
            "reason": HistoricalFindingReason.frameScopeMismatch.rawValue,
            "count": 1,
        ]]
        object["suppressionSummary"] = summary

        try expectRegressionDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: object,
            because: "A frame-incompatible comparison cannot retain causal findings."
        )

        object = try regressionJSONObject(unchangedRegressionResult())
        summary = try regressionSummary(from: object)
        summary["findingSuppressions"] = [
            [
                "reason": HistoricalFindingReason.endpointScopeMismatch.rawValue,
                "count": 1,
            ],
            [
                "reason": HistoricalFindingReason.frameScopeMismatch.rawValue,
                "count": 1,
            ],
        ]
        object["suppressionSummary"] = summary

        try expectRegressionDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: object,
            because: "A frame-level early return cannot mix endpoint suppressions."
        )

        object = try regressionJSONObject(unchangedRegressionResult())
        summary = try regressionSummary(from: object)
        summary["findingSuppressions"] = [[
            "reason": HistoricalFindingReason.frameNonIncreasingSequence.rawValue,
            "count": 1,
        ]]
        object["suppressionSummary"] = summary
        try expectRegressionDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: object,
            because: "An increasing frame pair cannot claim a non-increasing sequence."
        )

        let prioritized = try HistoricalFindingGenerator().generate(
            baseline: regressionFrame(
                sequence: 2,
                endpointPrefix: "priority-baseline",
                scopeID: "scope-a"
            ),
            comparison: regressionFrame(
                sequence: 1,
                endpointPrefix: "priority-comparison",
                scopeID: "scope-b"
            )
        )
        #expect(prioritized.batch.comparisonSequence < prioritized.batch.baselineSequence)
        #expect(prioritized.batch.findings.isEmpty)
        #expect(prioritized.suppressionSummary.findingSuppressions.count == 1)
        #expect(
            prioritized.suppressionSummary.findingSuppressions.first?.reason
                == .frameScopeMismatch
        )
        #expect(prioritized.suppressionSummary.findingSuppressions.first?.count == 1)
        let prioritizedData = try JSONEncoder().encode(prioritized)
        #expect(
            try JSONDecoder().decode(
                HistoricalFindingGenerationResult.self,
                from: prioritizedData
            ) == prioritized
        )
    }

    @Test("Collapse summaries require the retained ancestor kind they reference")
    func collapseSummaryRequiresRetainedCausalKinds() throws {
        let unsupported: [HistoricalFindingReason] = [
            .collapsedImplicitDescendantMove,
            .collapsedInheritedMoveFacet,
            .coveredByAncestorAppearance,
            .coveredByAncestorDisappearance,
        ]

        for reason in unsupported {
            var object = try regressionJSONObject(twoGrowthRegressionResult())
            var summary = try regressionSummary(from: object)
            summary["collapses"] = [[
                "reason": reason.rawValue,
                "count": 1,
            ]]
            object["suppressionSummary"] = summary

            try expectRegressionDecodingRejected(
                HistoricalFindingGenerationResult.self,
                object: object,
                because: "Collapse reason \(reason.rawValue) requires retained causal evidence."
            )
        }

        var inherited = try regressionJSONObject(inheritedMovementRegressionResult())
        var inheritedSummary = try regressionSummary(from: inherited)
        inheritedSummary["collapses"] = [[
            "reason": HistoricalFindingReason.collapsedInheritedMoveFacet.rawValue,
            "count": 2,
        ]]
        inherited["suppressionSummary"] = inheritedSummary
        try expectRegressionDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: inherited,
            because: "Each retained inherited byte-change draft contributes exactly one collapse."
        )
    }

    @Test("Ranking exclusion reasons must match the retained draft state")
    func rankingExclusionReasonsMatchRetainedDrafts() throws {
        var object = try regressionJSONObject(inheritedMovementRegressionResult())
        var summary = try regressionSummary(from: object)
        summary["rankingExclusions"] = [[
            "reason": HistoricalFindingReason.rankingIncompleteDirectChildren.rawValue,
            "count": 1,
        ]]
        object["suppressionSummary"] = summary

        try expectRegressionDecodingRejected(
            HistoricalFindingGenerationResult.self,
            object: object,
            because: "A move is kind-ineligible; it never performs child-flow ranking."
        )
    }

    @Test("Finding keys and inherited-movement discriminants are strict durable values")
    func keysAndMovementContextsRejectUnknownOrContradictoryPayloads() throws {
        let result = try inheritedMovementRegressionResult()
        let findings = try #require(
            regressionJSONObject(result.batch)["findings"] as? [[String: Any]]
        )
        let inherited = try #require(findings.first { $0["movementContext"] != nil })
        let validKey = try #require(inherited["key"] as? [String: Any])
        let validMovement = try #require(
            inherited["movementContext"] as? [String: Any]
        )

        var unknownKeyField = validKey
        unknownKeyField["future"] = true
        try expectRegressionDecodingRejected(
            HistoricalFindingKey.self,
            object: unknownKeyField,
            because: "An idempotency key cannot silently discard a future field."
        )

        var unknownKeyKind = validKey
        unknownKeyKind["kind"] = "future_finding_kind"
        try expectRegressionDecodingRejected(
            HistoricalFindingKey.self,
            object: unknownKeyKind,
            because: "An idempotency key cannot reinterpret an unknown finding kind."
        )

        var reusedEndpointKey = validKey
        reusedEndpointKey["comparisonEndpointID"] = reusedEndpointKey["baselineEndpointID"]
        try expectRegressionDecodingRejected(
            HistoricalFindingKey.self,
            object: reusedEndpointKey,
            because: "An idempotency key cannot identify both evidence sides with one endpoint."
        )

        var unknownMovementField = validMovement
        unknownMovementField["future"] = true
        try expectRegressionDecodingRejected(
            HistoricalFindingMovementContext.self,
            object: unknownMovementField,
            because: "Movement context cannot silently discard a future field."
        )

        var unknownMovementKind = validMovement
        unknownMovementKind["kind"] = "future_movement_kind"
        try expectRegressionDecodingRejected(
            HistoricalFindingMovementContext.self,
            object: unknownMovementKind,
            because: "Movement context requires a recognized discriminant."
        )

        var missingAncestor = validMovement
        missingAncestor.removeValue(forKey: "ancestorKey")
        try expectRegressionDecodingRejected(
            HistoricalFindingMovementContext.self,
            object: missingAncestor,
            because: "Inherited movement requires its ancestor key payload."
        )
    }

    @Test("Drafts reject unknown fields inside either embedded storage delta")
    func draftsRejectUnknownEmbeddedStorageDeltaFields() throws {
        let result = try twoGrowthRegressionResult()
        let batch = try regressionJSONObject(result.batch)
        let findings = try #require(batch["findings"] as? [[String: Any]])
        let validDraft = try #require(findings.first)

        for deltaField in ["inclusiveDelta", "rankingContribution"] {
            var draft = validDraft
            var delta = try #require(draft[deltaField] as? [String: Any])
            delta["future"] = true
            draft[deltaField] = delta

            try expectRegressionDecodingRejected(
                HistoricalFindingDraft.self,
                object: draft,
                because: "The embedded \(deltaField) cannot discard unknown evidence."
            )
        }
    }
}

struct NonIncreasingSequenceCase: Sendable, CustomTestStringConvertible {
    let baseline: Int64
    let comparison: Int64

    var testDescription: String {
        "baseline=\(baseline), comparison=\(comparison)"
    }
}

private enum RegressionNodeState {
    case present(Int64)
    case absent
}

private struct RegressionNodeFixture {
    let subjectID: String
    let parentSubjectID: String
    let path: String
    let locationID: String
    let state: RegressionNodeState
    let identityBasis: ObservationSubjectIdentityBasis
    let stableIdentityEvidence: HistoricalFindingStableIdentityEvidence?
}

private func regressionFrame(
    sequence: Int64,
    endpointPrefix: String,
    rootBytes: Int64 = 1_000,
    scopeID: String = "scope-a",
    children: [RegressionNodeFixture] = []
) throws -> HistoricalFindingObservationFrame {
    let root = try regressionNode(
        endpointID: "\(endpointPrefix)-root",
        subjectID: "root",
        parentSubjectID: nil,
        path: "/Fixtures",
        displayName: "Fixtures",
        locationID: "location-root",
        state: .present(rootBytes),
        identityBasis: .normalizedPath,
        stableIdentityEvidence: nil,
        sequence: sequence,
        scopeID: scopeID,
        endpointPrefix: endpointPrefix
    )
    let childNodes = try children.map { fixture in
        try regressionNode(
            endpointID: "\(endpointPrefix)-\(fixture.subjectID)",
            subjectID: fixture.subjectID,
            parentSubjectID: fixture.parentSubjectID,
            path: fixture.path,
            displayName: String(fixture.path.split(separator: "/").last ?? "Fixtures"),
            locationID: fixture.locationID,
            state: fixture.state,
            identityBasis: fixture.identityBasis,
            stableIdentityEvidence: fixture.stableIdentityEvidence,
            sequence: sequence,
            scopeID: scopeID,
            endpointPrefix: endpointPrefix
        )
    }
    return try HistoricalFindingObservationFrame(
        rootSubjectID: SubjectID("root"),
        rootPath: "/Fixtures",
        nodes: [root] + childNodes
    )
}

private func regressionNode(
    endpointID: String,
    subjectID: String,
    parentSubjectID: String?,
    path: String,
    displayName: String,
    locationID: String,
    state: RegressionNodeState,
    identityBasis: ObservationSubjectIdentityBasis,
    stableIdentityEvidence: HistoricalFindingStableIdentityEvidence?,
    sequence: Int64,
    scopeID: String,
    endpointPrefix: String
) throws -> HistoricalFindingNode {
    let endpointState: ObservationEndpointState
    let classification: VersionedAttributionDecision?
    switch state {
    case .present(let bytes):
        endpointState = .present(bytes: try ByteCount(bytes), coverage: .complete)
        classification = try regressionDecision()
    case .absent:
        let parentSubjectID = try #require(parentSubjectID)
        endpointState = .absent(
            ParentAbsenceReference(
                parentEndpointID: try ObservationEndpointID(
                    "\(endpointPrefix)-\(parentSubjectID)"
                ),
                parentSubjectID: try SubjectID(parentSubjectID)
            )
        )
        classification = nil
    }

    let endpoint = try ObservationEndpoint(
        id: ObservationEndpointID(endpointID),
        scopeID: ScopeID(scopeID),
        volumeID: ObservationVolumeID("volume-a"),
        mountGenerationID: ObservationMountGenerationID("mount-a"),
        coverageEpochID: ObservationCoverageEpochID("coverage-a"),
        subjectID: SubjectID(subjectID),
        identityBasis: identityBasis,
        locationID: ObservationLocationID(locationID),
        metric: .logical,
        pathSemanticsVersion: ObservationSemanticsVersion(1),
        measurementSemanticsVersion: ObservationSemanticsVersion(1),
        sequence: ObservationCommitSequence(sequence),
        observedAt: ObservationInstant(millisecondsSince1970: sequence * 1_000),
        state: endpointState
    )
    return try HistoricalFindingNode(
        endpoint: endpoint,
        parentSubjectID: try parentSubjectID.map(SubjectID.init),
        path: path,
        displayName: displayName,
        directChildrenCoverage: state.isPresent ? .complete : .unknown,
        classification: classification,
        stableIdentityEvidence: stableIdentityEvidence
    )
}

private func regressionDecision() throws -> VersionedAttributionDecision {
    try VersionedAttributionDecision(
        catalogVersion: AttributionCatalogVersion(1),
        result: .unknown(.noMatchingRule)
    )
}

private func regressionStableEvidence(
    token: String
) throws -> HistoricalFindingStableIdentityEvidence {
    try HistoricalFindingStableIdentityEvidence(
        reuseGuard: .generationToken(token),
        nodeKind: .directory,
        linkStatus: .unique
    )
}

private func unchangedRegressionResult() throws -> HistoricalFindingGenerationResult {
    try HistoricalFindingGenerator().generate(
        baseline: regressionFrame(sequence: 1, endpointPrefix: "baseline"),
        comparison: regressionFrame(sequence: 2, endpointPrefix: "comparison")
    )
}

private func twoGrowthRegressionResult() throws -> HistoricalFindingGenerationResult {
    let baselineChildren = [
        regressionPresentFixture(subject: "first", path: "/Fixtures/First", bytes: 10),
        regressionPresentFixture(subject: "second", path: "/Fixtures/Second", bytes: 20),
    ]
    let comparisonChildren = [
        regressionPresentFixture(subject: "first", path: "/Fixtures/First", bytes: 15),
        regressionPresentFixture(subject: "second", path: "/Fixtures/Second", bytes: 30),
    ]
    return try HistoricalFindingGenerator().generate(
        baseline: regressionFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            children: baselineChildren
        ),
        comparison: regressionFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            children: comparisonChildren
        )
    )
}

private func appearanceRegressionResult() throws -> HistoricalFindingGenerationResult {
    try HistoricalFindingGenerator().generate(
        baseline: regressionFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            children: [
                RegressionNodeFixture(
                    subjectID: "appeared",
                    parentSubjectID: "root",
                    path: "/Fixtures/Appeared",
                    locationID: "location-appeared",
                    state: .absent,
                    identityBasis: .normalizedPath,
                    stableIdentityEvidence: nil
                ),
            ]
        ),
        comparison: regressionFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            children: [
                regressionPresentFixture(
                    subject: "appeared",
                    path: "/Fixtures/Appeared",
                    bytes: 20
                ),
            ]
        )
    )
}

private func disappearanceRegressionResult() throws -> HistoricalFindingGenerationResult {
    try HistoricalFindingGenerator().generate(
        baseline: regressionFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            children: [
                regressionPresentFixture(
                    subject: "disappeared",
                    path: "/Fixtures/Disappeared",
                    bytes: 20
                ),
            ]
        ),
        comparison: regressionFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            children: [
                RegressionNodeFixture(
                    subjectID: "disappeared",
                    parentSubjectID: "root",
                    path: "/Fixtures/Disappeared",
                    locationID: "location-disappeared",
                    state: .absent,
                    identityBasis: .normalizedPath,
                    stableIdentityEvidence: nil
                ),
            ]
        )
    )
}

private func inheritedMovementRegressionResult() throws -> HistoricalFindingGenerationResult {
    let parentEvidence = try regressionStableEvidence(token: "parent-generation")
    let childEvidence = try regressionStableEvidence(token: "child-generation")
    let baselineChildren = [
        regressionPresentFixture(
            subject: "moving-parent",
            path: "/Fixtures/Old",
            bytes: 100,
            locationID: "parent-old",
            identityBasis: .stableFileSystemObject,
            stableIdentityEvidence: parentEvidence
        ),
        regressionPresentFixture(
            subject: "moving-child",
            parent: "moving-parent",
            path: "/Fixtures/Old/Child",
            bytes: 10,
            locationID: "child-old",
            identityBasis: .stableFileSystemObject,
            stableIdentityEvidence: childEvidence
        ),
    ]
    let comparisonChildren = [
        regressionPresentFixture(
            subject: "moving-parent",
            path: "/Fixtures/New",
            bytes: 105,
            locationID: "parent-new",
            identityBasis: .stableFileSystemObject,
            stableIdentityEvidence: parentEvidence
        ),
        regressionPresentFixture(
            subject: "moving-child",
            parent: "moving-parent",
            path: "/Fixtures/New/Child",
            bytes: 15,
            locationID: "child-new",
            identityBasis: .stableFileSystemObject,
            stableIdentityEvidence: childEvidence
        ),
    ]
    return try HistoricalFindingGenerator().generate(
        baseline: regressionFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            children: baselineChildren
        ),
        comparison: regressionFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            children: comparisonChildren
        )
    )
}

private func regressionPresentFixture(
    subject: String,
    parent: String = "root",
    path: String,
    bytes: Int64,
    locationID: String? = nil,
    identityBasis: ObservationSubjectIdentityBasis = .normalizedPath,
    stableIdentityEvidence: HistoricalFindingStableIdentityEvidence? = nil
) -> RegressionNodeFixture {
    RegressionNodeFixture(
        subjectID: subject,
        parentSubjectID: parent,
        path: path,
        locationID: locationID ?? "location-\(subject)",
        state: .present(bytes),
        identityBasis: identityBasis,
        stableIdentityEvidence: stableIdentityEvidence
    )
}

private func canonicalNonIncreasingResultObject() throws -> [String: Any] {
    var result = try regressionJSONObject(unchangedRegressionResult())
    var batch = try regressionBatch(from: result)
    batch["comparisonSequence"] = batch["baselineSequence"]
    result["batch"] = batch
    var summary = try regressionSummary(from: result)
    summary["findingSuppressions"] = [[
        "reason": HistoricalFindingReason.frameNonIncreasingSequence.rawValue,
        "count": 1,
    ]]
    result["suppressionSummary"] = summary
    return result
}

private func expectStrictNonIncreasingSummary(
    _ summary: HistoricalFindingSuppressionSummary
) throws {
    #expect(summary.findingSuppressions.count == 1)
    let reasonCount = try #require(summary.findingSuppressions.first)
    #expect(reasonCount.reason == .frameNonIncreasingSequence)
    #expect(reasonCount.count == 1)
    #expect(summary.rankingExclusions.isEmpty)
    #expect(summary.collapses.isEmpty)
    #expect(summary.truncatedPositiveCount == 0)
}

private func expectRegressionDecodingRejected<T: Decodable>(
    _ type: T.Type,
    object: [String: Any],
    because message: String
) throws {
    let data = try regressionJSONData(object)
    #expect(throws: DecodingError.self, Comment(rawValue: message)) {
        try JSONDecoder().decode(type, from: data)
    }
}

private func regressionJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
}

private func regressionJSONData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func regressionBatch(from result: [String: Any]) throws -> [String: Any] {
    try #require(result["batch"] as? [String: Any])
}

private func regressionSummary(from result: [String: Any]) throws -> [String: Any] {
    try #require(result["suppressionSummary"] as? [String: Any])
}

private extension RegressionNodeState {
    var isPresent: Bool {
        if case .present = self { return true }
        return false
    }
}
