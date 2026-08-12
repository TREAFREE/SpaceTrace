import Testing
import SpaceTraceAttribution
import SpaceTraceDomain
@testable import SpaceTraceApplication

struct HistoricalCalibrationAbsenceReconcilerTests {
    @Test("Only the topmost missing directory becomes an explicit absence")
    func appendsTopmostAbsence() throws {
        let previous = try materializeLogicalFrame(
            candidate: candidate([
                node("root", path: "/Fixtures", parent: nil),
                node("parent", path: "/Fixtures/Parent", parent: "root"),
                node("child", path: "/Fixtures/Parent/Child", parent: "parent"),
            ])
        )
        let current = try candidate([
            node("root", path: "/Fixtures", parent: nil, observedAt: 2_000),
        ])

        let reconciled = try HistoricalCalibrationAbsenceReconciler().reconcile(
            current: current,
            previousLogicalFrame: previous
        )

        #expect(reconciled.nodes.count == 2)
        let absent = try #require(reconciled.nodes.first { $0.subjectID.rawValue == "parent" })
        guard case .absent = absent.state else {
            Issue.record("The topmost missing directory must carry explicit absence evidence.")
            return
        }
        #expect(absent.parentSubjectID?.rawValue == "root")
        #expect(absent.path == "/Fixtures/Parent")
        #expect(absent.observedAt.millisecondsSince1970 == 2_000)
        #expect(absent.classification == nil)
        #expect(absent.directChildrenCoverage == .unknown)
        #expect(reconciled.nodes.contains { $0.subjectID.rawValue == "child" } == false)
    }

    @Test("Incomplete direct-child evidence never synthesizes absence")
    func requiresCompleteCurrentParentEvidence() throws {
        let previous = try materializeLogicalFrame(
            candidate: candidate([
                node("root", path: "/Fixtures", parent: nil),
                node("child", path: "/Fixtures/Child", parent: "root"),
            ])
        )
        let current = try candidate([
            node(
                "root",
                path: "/Fixtures",
                parent: nil,
                directChildrenCoverage: .partial,
                observedAt: 2_000
            ),
        ])

        let reconciled = try HistoricalCalibrationAbsenceReconciler().reconcile(
            current: current,
            previousLogicalFrame: previous
        )

        #expect(reconciled == current)
    }

    @Test("A changed frame context never borrows absence evidence")
    func requiresCompatibleFrameContext() throws {
        let previous = try materializeLogicalFrame(
            candidate: candidate([
                node("root", path: "/Fixtures", parent: nil),
                node("child", path: "/Fixtures/Child", parent: "root"),
            ])
        )
        let current = try candidate(
            [node("root", path: "/Fixtures", parent: nil, observedAt: 2_000)],
            mountGeneration: "mount-replaced"
        )

        let reconciled = try HistoricalCalibrationAbsenceReconciler().reconcile(
            current: current,
            previousLogicalFrame: previous
        )

        #expect(reconciled == current)
    }

    @Test("A location occupied by a replacement object remains conservative")
    func doesNotCreateTwoObjectsAtOneLocation() throws {
        let previous = try materializeLogicalFrame(
            candidate: candidate([
                node("root", path: "/Fixtures", parent: nil),
                node("old-object", path: "/Fixtures/Child", parent: "root"),
            ])
        )
        let current = try candidate([
            node("root", path: "/Fixtures", parent: nil, observedAt: 2_000),
            node("new-object", path: "/Fixtures/Child", parent: "root", observedAt: 2_000),
        ])

        let reconciled = try HistoricalCalibrationAbsenceReconciler().reconcile(
            current: current,
            previousLogicalFrame: previous
        )

        #expect(reconciled == current)
    }
}

private func candidate(
    _ nodes: [HistoricalPairedObservationNodeCandidate],
    mountGeneration: String = "mount-a"
) throws -> HistoricalPairedObservationCandidate {
    try HistoricalPairedObservationCandidate(
        rootSubjectID: SubjectID("root"),
        rootPath: "/Fixtures",
        nodes: nodes,
        scopeID: ScopeID("scope-a"),
        volumeID: ObservationVolumeID("volume-a"),
        mountGenerationID: ObservationMountGenerationID(mountGeneration),
        coverageEpochID: ObservationCoverageEpochID("coverage-a"),
        pathSemanticsVersion: ObservationSemanticsVersion(1),
        measurementSemanticsVersion: ObservationSemanticsVersion(1)
    )
}

private func node(
    _ subject: String,
    path: String,
    parent: String?,
    directChildrenCoverage: ObservationCoverage = .complete,
    observedAt: Int64 = 1_000
) throws -> HistoricalPairedObservationNodeCandidate {
    try HistoricalPairedObservationNodeCandidate(
        subjectID: SubjectID(subject),
        identityBasis: .normalizedPath,
        parentSubjectID: try parent.map(SubjectID.init),
        locationID: ObservationLocationID("location:\(path)"),
        path: path,
        displayName: path == "/Fixtures" ? "Fixtures" : String(path.split(separator: "/").last!),
        observedAt: ObservationInstant(millisecondsSince1970: observedAt),
        state: .present(
            logicalBytes: ByteCount(100),
            allocatedBytes: ByteCount(128),
            measurementCoverage: .complete
        ),
        directChildrenCoverage: directChildrenCoverage,
        classification: VersionedAttributionDecision(
            catalogVersion: AttributionCatalogVersion(1),
            result: .unknown(.noMatchingRule)
        ),
        stableIdentityEvidence: nil
    )
}

private func materializeLogicalFrame(
    candidate: HistoricalPairedObservationCandidate
) throws -> HistoricalFindingObservationFrame {
    let nodeIDs = Dictionary(
        uniqueKeysWithValues: candidate.nodes.enumerated().map { offset, node in
            (node.subjectID, Int64(offset + 1))
        }
    )
    return try HistoricalPairedObservationCommitMaterializer(candidate: candidate)
        .materialize(
            storeGeneration: HistoricalStoreGeneration(
                bytes: Array(repeating: 0xA5, count: 16)
            ),
            nodeIDs: nodeIDs,
            logicalSequence: ObservationCommitSequence(1),
            allocatedSequence: ObservationCommitSequence(2)
        )
        .logical
}
