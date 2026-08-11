import Foundation
import Testing
import SpaceTraceAttribution
import SpaceTraceDomain
@testable import SpaceTraceApplication

struct HistoricalFindingModelTests {
    @Test("An observation frame cannot be empty")
    func rejectsEmptyFrame() throws {
        #expect(throws: HistoricalFindingModelError.self) {
            try HistoricalFindingObservationFrame(
                rootSubjectID: SubjectID("root"),
                rootPath: "/Fixtures",
                nodes: []
            )
        }
    }

    @Test("A frame requires exactly one root node at the declared root path")
    func rejectsMissingOrMisplacedRoot() throws {
        let child = try makeNode(
            endpointID: "endpoint-child",
            subjectID: "child",
            locationID: "location-child",
            parentSubjectID: nil,
            path: "/Fixtures",
            displayName: "Fixtures"
        )
        #expect(throws: HistoricalFindingModelError.self) {
            try makeFrame(rootSubjectID: "root", nodes: [child])
        }

        let misplacedRoot = try makeNode(
            endpointID: "endpoint-root",
            subjectID: "root",
            locationID: "location-root",
            parentSubjectID: nil,
            path: "/Fixtures/Nested",
            displayName: "Nested"
        )
        #expect(throws: HistoricalFindingModelError.self) {
            try makeFrame(nodes: [misplacedRoot])
        }
    }

    @Test("Subject, endpoint, location, and path identities are unique within a frame")
    func rejectsDuplicateIdentities() throws {
        let root = try makeRootNode()

        let firstSubject = try makeNode(
            endpointID: "endpoint-first-subject",
            subjectID: "duplicate-subject",
            locationID: "location-first-subject",
            parentSubjectID: "root",
            path: "/Fixtures/FirstSubject",
            displayName: "FirstSubject"
        )
        let secondSubject = try makeNode(
            endpointID: "endpoint-second-subject",
            subjectID: "duplicate-subject",
            locationID: "location-second-subject",
            parentSubjectID: "root",
            path: "/Fixtures/SecondSubject",
            displayName: "SecondSubject"
        )
        #expect(throws: HistoricalFindingModelError.self) {
            try makeFrame(nodes: [root, firstSubject, secondSubject])
        }

        let firstEndpoint = try makeNode(
            endpointID: "duplicate-endpoint",
            subjectID: "first-endpoint-subject",
            locationID: "location-first-endpoint",
            parentSubjectID: "root",
            path: "/Fixtures/FirstEndpoint",
            displayName: "FirstEndpoint"
        )
        let secondEndpoint = try makeNode(
            endpointID: "duplicate-endpoint",
            subjectID: "second-endpoint-subject",
            locationID: "location-second-endpoint",
            parentSubjectID: "root",
            path: "/Fixtures/SecondEndpoint",
            displayName: "SecondEndpoint"
        )
        #expect(throws: HistoricalFindingModelError.self) {
            try makeFrame(nodes: [root, firstEndpoint, secondEndpoint])
        }

        let firstLocation = try makeNode(
            endpointID: "endpoint-first-location",
            subjectID: "first-location-subject",
            locationID: "duplicate-location",
            parentSubjectID: "root",
            path: "/Fixtures/FirstLocation",
            displayName: "FirstLocation"
        )
        let secondLocation = try makeNode(
            endpointID: "endpoint-second-location",
            subjectID: "second-location-subject",
            locationID: "duplicate-location",
            parentSubjectID: "root",
            path: "/Fixtures/SecondLocation",
            displayName: "SecondLocation"
        )
        #expect(throws: HistoricalFindingModelError.self) {
            try makeFrame(nodes: [root, firstLocation, secondLocation])
        }

        let firstPath = try makeNode(
            endpointID: "endpoint-first-path",
            subjectID: "first-path-subject",
            locationID: "location-first-path",
            parentSubjectID: "root",
            path: "/Fixtures/DuplicatePath",
            displayName: "DuplicatePath"
        )
        let secondPath = try makeNode(
            endpointID: "endpoint-second-path",
            subjectID: "second-path-subject",
            locationID: "location-second-path",
            parentSubjectID: "root",
            path: "/Fixtures/DuplicatePath",
            displayName: "DuplicatePath"
        )
        #expect(throws: HistoricalFindingModelError.self) {
            try makeFrame(nodes: [root, firstPath, secondPath])
        }
    }

    @Test("Root containment is path-component aware")
    func rejectsNodesOutsideRoot() throws {
        let root = try makeRootNode()

        for outsidePath in ["/Elsewhere/Child", "/Fixtures-escape/Child"] {
            let child = try makeNode(
                endpointID: "endpoint-outside",
                subjectID: "outside",
                locationID: "location-outside",
                parentSubjectID: "root",
                path: outsidePath,
                displayName: "Child"
            )
            #expect(throws: HistoricalFindingModelError.self) {
                try makeFrame(nodes: [root, child])
            }
        }
    }

    @Test("Frame paths must be absolute and lexically normalized")
    func rejectsNonCanonicalPaths() throws {
        for invalidPath in [
            "Fixtures/Child",
            "/Fixtures//Child",
            "/Fixtures/./Child",
            "/Fixtures/../Child",
            "/Fixtures/Child/",
        ] {
            #expect(throws: HistoricalFindingModelError.self) {
                try makeNode(
                    endpointID: "endpoint-invalid-path",
                    subjectID: "invalid-path",
                    locationID: "location-invalid-path",
                    parentSubjectID: "root",
                    path: invalidPath,
                    displayName: "Child"
                )
            }
        }
    }

    @Test("Every non-root node resolves to a lexical direct parent")
    func rejectsMissingAndNonDirectParents() throws {
        let root = try makeRootNode()
        let missingParent = try makeNode(
            endpointID: "endpoint-missing-parent",
            subjectID: "missing-parent-child",
            locationID: "location-missing-parent",
            parentSubjectID: "not-in-frame",
            path: "/Fixtures/Child",
            displayName: "Child"
        )
        #expect(throws: HistoricalFindingModelError.self) {
            try makeFrame(nodes: [root, missingParent])
        }

        let nonDirectChild = try makeNode(
            endpointID: "endpoint-non-direct",
            subjectID: "non-direct-child",
            locationID: "location-non-direct",
            parentSubjectID: "root",
            path: "/Fixtures/Skipped/Child",
            displayName: "Child"
        )
        #expect(throws: HistoricalFindingModelError.self) {
            try makeFrame(nodes: [root, nonDirectChild])
        }
    }

    @Test("A node cannot exist below an absent or unknown parent")
    func rejectsChildrenBelowUnavailableParents() throws {
        let root = try makeRootNode()
        let rootReference = ParentAbsenceReference(
            parentEndpointID: root.endpoint.id,
            parentSubjectID: root.endpoint.subjectID
        )
        let unavailableStates: [ObservationEndpointState] = [
            .absent(rootReference),
            .unknown(.continuityGap),
        ]

        for (index, state) in unavailableStates.enumerated() {
            let parent = try makeNode(
                endpointID: "endpoint-unavailable-parent-\(index)",
                subjectID: "unavailable-parent-\(index)",
                locationID: "location-unavailable-parent-\(index)",
                parentSubjectID: "root",
                path: "/Fixtures/Unavailable\(index)",
                displayName: "Unavailable\(index)",
                state: state,
                directChildrenCoverage: .unknown
            )
            let child = try makeNode(
                endpointID: "endpoint-child-below-unavailable-\(index)",
                subjectID: "child-below-unavailable-\(index)",
                locationID: "location-child-below-unavailable-\(index)",
                parentSubjectID: "unavailable-parent-\(index)",
                path: "/Fixtures/Unavailable\(index)/Child",
                displayName: "Child"
            )

            #expect(throws: HistoricalFindingModelError.unavailableParentCannotContainNode) {
                try makeFrame(nodes: [root, parent, child])
            }
        }
    }

    @Test("Parent relationships cannot form a cycle")
    func rejectsCyclicParents() throws {
        let root = try makeRootNode()
        let first = try makeNode(
            endpointID: "endpoint-cycle-first",
            subjectID: "cycle-first",
            locationID: "location-cycle-first",
            parentSubjectID: "cycle-second",
            path: "/Fixtures/First",
            displayName: "First"
        )
        let second = try makeNode(
            endpointID: "endpoint-cycle-second",
            subjectID: "cycle-second",
            locationID: "location-cycle-second",
            parentSubjectID: "cycle-first",
            path: "/Fixtures/First/Second",
            displayName: "Second"
        )

        #expect(throws: HistoricalFindingModelError.self) {
            try makeFrame(nodes: [root, first, second])
        }
    }

    @Test("All endpoints in one frame share one measurement and commit context")
    func rejectsInconsistentFrameContext() throws {
        let root = try makeRootNode()

        for mismatch in FrameContextMismatch.allCases {
            let child = try makeNode(
                endpointID: "endpoint-mismatch-\(mismatch.rawValue)",
                subjectID: "subject-mismatch-\(mismatch.rawValue)",
                locationID: "location-mismatch-\(mismatch.rawValue)",
                parentSubjectID: "root",
                path: "/Fixtures/\(mismatch.rawValue)",
                displayName: mismatch.rawValue,
                scopeID: mismatch == .scope ? "scope-b" : "scope-a",
                volumeID: mismatch == .volume ? "volume-b" : "volume-a",
                mountGenerationID: mismatch == .mount ? "mount-b" : "mount-a",
                coverageEpochID: mismatch == .coverageEpoch ? "coverage-b" : "coverage-a",
                metric: mismatch == .metric ? .allocated : .logical,
                pathSemanticsVersion: mismatch == .pathSemantics ? 2 : 1,
                measurementSemanticsVersion: mismatch == .measurementSemantics ? 2 : 1,
                sequence: mismatch == .sequence ? 2 : 1
            )

            #expect(throws: HistoricalFindingModelError.self) {
                try makeFrame(nodes: [root, child])
            }
        }
    }

    @Test("Directory finding frames reject whole-volume available capacity")
    func rejectsVolumeAvailableMetric() throws {
        let root = try makeNode(
            endpointID: "endpoint-volume-root",
            subjectID: "root",
            locationID: "location-volume-root",
            parentSubjectID: nil,
            path: "/Fixtures",
            displayName: "Fixtures",
            metric: .volumeAvailable
        )
        let child = try makeNode(
            endpointID: "endpoint-volume-child",
            subjectID: "volume-child",
            locationID: "location-volume-child",
            parentSubjectID: "root",
            path: "/Fixtures/Child",
            displayName: "Child",
            metric: .volumeAvailable
        )

        #expect(throws: HistoricalFindingModelError.self) {
            try makeFrame(nodes: [root, child])
        }
    }

    @Test("Only present nodes carry a frozen classification decision")
    func enforcesClassificationByEndpointState() throws {
        #expect(throws: HistoricalFindingModelError.self) {
            try makeNode(
                endpointID: "endpoint-present-unclassified",
                subjectID: "present-unclassified",
                locationID: "location-present-unclassified",
                parentSubjectID: "root",
                path: "/Fixtures/Present",
                displayName: "Present",
                classification: .none
            )
        }

        let decision = try makeClassificationDecision()
        let parentReference = ParentAbsenceReference(
            parentEndpointID: try ObservationEndpointID("endpoint-root"),
            parentSubjectID: try SubjectID("root")
        )
        #expect(throws: HistoricalFindingModelError.self) {
            try makeNode(
                endpointID: "endpoint-absent-classified",
                subjectID: "absent-classified",
                locationID: "location-absent-classified",
                parentSubjectID: "root",
                path: "/Fixtures/Absent",
                displayName: "Absent",
                state: .absent(parentReference),
                classification: .exact(decision)
            )
        }
        #expect(throws: HistoricalFindingModelError.self) {
            try makeNode(
                endpointID: "endpoint-unknown-classified",
                subjectID: "unknown-classified",
                locationID: "location-unknown-classified",
                parentSubjectID: "root",
                path: "/Fixtures/Unknown",
                displayName: "Unknown",
                state: .unknown(.continuityGap),
                classification: .exact(decision)
            )
        }
    }

    @Test("Absence proof resolves to the complete direct parent in the same frame")
    func validatesAbsenceParentEvidence() throws {
        let root = try makeRootNode()
        let validReference = ParentAbsenceReference(
            parentEndpointID: root.endpoint.id,
            parentSubjectID: root.endpoint.subjectID
        )
        let validAbsence = try makeNode(
            endpointID: "endpoint-valid-absence",
            subjectID: "valid-absence",
            locationID: "location-valid-absence",
            parentSubjectID: "root",
            path: "/Fixtures/Absent",
            displayName: "Absent",
            state: .absent(validReference),
            directChildrenCoverage: .unknown
        )
        #expect(try makeFrame(nodes: [root, validAbsence]).nodes.count == 2)

        let missingReference = ParentAbsenceReference(
            parentEndpointID: try ObservationEndpointID("endpoint-not-in-frame"),
            parentSubjectID: try SubjectID("root")
        )
        let unresolvedAbsence = try makeNode(
            endpointID: "endpoint-unresolved-absence",
            subjectID: "unresolved-absence",
            locationID: "location-unresolved-absence",
            parentSubjectID: "root",
            path: "/Fixtures/Unresolved",
            displayName: "Unresolved",
            state: .absent(missingReference),
            directChildrenCoverage: .unknown
        )
        #expect(throws: HistoricalFindingModelError.self) {
            try makeFrame(nodes: [root, unresolvedAbsence])
        }

        let partialParent = try makeRootNode(
            endpointState: .present(bytes: ByteCount(4_096), coverage: .partial)
        )
        let partialReference = ParentAbsenceReference(
            parentEndpointID: partialParent.endpoint.id,
            parentSubjectID: partialParent.endpoint.subjectID
        )
        let absenceBelowPartialParent = try makeNode(
            endpointID: "endpoint-partial-parent-absence",
            subjectID: "partial-parent-absence",
            locationID: "location-partial-parent-absence",
            parentSubjectID: "root",
            path: "/Fixtures/PartialParent",
            displayName: "PartialParent",
            state: .absent(partialReference),
            directChildrenCoverage: .unknown
        )
        #expect(throws: HistoricalFindingModelError.self) {
            try makeFrame(nodes: [partialParent, absenceBelowPartialParent])
        }

        let incompleteChildrenParent = try makeRootNode(directChildrenCoverage: .partial)
        let incompleteChildrenReference = ParentAbsenceReference(
            parentEndpointID: incompleteChildrenParent.endpoint.id,
            parentSubjectID: incompleteChildrenParent.endpoint.subjectID
        )
        let absenceBelowIncompleteChildren = try makeNode(
            endpointID: "endpoint-incomplete-children-absence",
            subjectID: "incomplete-children-absence",
            locationID: "location-incomplete-children-absence",
            parentSubjectID: "root",
            path: "/Fixtures/IncompleteChildren",
            displayName: "IncompleteChildren",
            state: .absent(incompleteChildrenReference),
            directChildrenCoverage: .unknown
        )
        #expect(throws: HistoricalFindingModelError.self) {
            try makeFrame(nodes: [incompleteChildrenParent, absenceBelowIncompleteChildren])
        }

        let directParent = try makeNode(
            endpointID: "endpoint-direct-parent",
            subjectID: "direct-parent",
            locationID: "location-direct-parent",
            parentSubjectID: "root",
            path: "/Fixtures/DirectParent",
            displayName: "DirectParent"
        )
        let grandchildReferringToRoot = try makeNode(
            endpointID: "endpoint-grandchild-absence",
            subjectID: "grandchild-absence",
            locationID: "location-grandchild-absence",
            parentSubjectID: "direct-parent",
            path: "/Fixtures/DirectParent/Grandchild",
            displayName: "Grandchild",
            state: .absent(validReference),
            directChildrenCoverage: .unknown
        )
        #expect(throws: HistoricalFindingModelError.self) {
            try makeFrame(nodes: [root, directParent, grandchildReferringToRoot])
        }
    }

    @Test("Display names reject only structurally unsafe or non-names")
    func rejectsInvalidDisplayNames() throws {
        for invalidDisplayName in ["", ".", "..", "bad/name", "bad\0name"] {
            #expect(throws: HistoricalFindingModelError.self) {
                try makeNode(
                    endpointID: "endpoint-invalid-name",
                    subjectID: "invalid-name",
                    locationID: "location-invalid-name",
                    parentSubjectID: "root",
                    path: "/Fixtures/ValidPath",
                    displayName: invalidDisplayName
                )
            }
        }
    }

    @Test("Legal whitespace and control-character display names survive Codable unchanged")
    func legalUntrustedDisplayNamesRoundTripAsInertText() throws {
        for (index, displayName) in [" ", "\t", "\n"].enumerated() {
            let node = try makeNode(
                endpointID: "endpoint-untrusted-name-\(index)",
                subjectID: "untrusted-name-\(index)",
                locationID: "location-untrusted-name-\(index)",
                parentSubjectID: "root",
                path: "/Fixtures/\(displayName)",
                displayName: displayName
            )

            let encoded = try JSONEncoder().encode(node)
            let decoded = try JSONDecoder().decode(HistoricalFindingNode.self, from: encoded)

            #expect(decoded == node)
            #expect(decoded.displayName == displayName)
        }
    }

    @Test("Stable identity evidence belongs only to stable-object subjects")
    func validatesStableIdentityEvidenceBasis() throws {
        let evidence = try HistoricalFindingStableIdentityEvidence(
            reuseGuard: .generationToken("generation-a"),
            nodeKind: .directory,
            linkStatus: .unique
        )

        #expect(throws: HistoricalFindingModelError.self) {
            try makeNode(
                endpointID: "endpoint-path-identity",
                subjectID: "path-identity",
                locationID: "location-path-identity",
                parentSubjectID: "root",
                path: "/Fixtures/PathIdentity",
                displayName: "PathIdentity",
                identityBasis: .normalizedPath,
                stableIdentityEvidence: evidence
            )
        }

        let stableWithoutMoveProof = try makeNode(
            endpointID: "endpoint-stable-without-proof",
            subjectID: "stable-without-proof",
            locationID: "location-stable-without-proof",
            parentSubjectID: "root",
            path: "/Fixtures/StableWithoutProof",
            displayName: "StableWithoutProof",
            identityBasis: .stableFileSystemObject,
            stableIdentityEvidence: nil
        )
        #expect(stableWithoutMoveProof.stableIdentityEvidence == nil)
    }

    @Test("Filesystem birth-time reuse guards preserve nanosecond evidence")
    func validatesNanosecondBirthTimeEvidence() throws {
        #expect(throws: HistoricalFindingModelError.invalidStableIdentityBirthTime) {
            try HistoricalFindingBirthTime(secondsSince1970: -1, nanoseconds: 0)
        }
        for invalidNanoseconds in [Int32(-1), Int32(1_000_000_000)] {
            #expect(throws: HistoricalFindingModelError.invalidStableIdentityBirthTime) {
                try HistoricalFindingBirthTime(
                    secondsSince1970: 1,
                    nanoseconds: invalidNanoseconds
                )
            }
        }

        for nanoseconds in [Int32(0), Int32(999_999_999)] {
            let birthTime = try HistoricalFindingBirthTime(
                secondsSince1970: 1_000,
                nanoseconds: nanoseconds
            )
            let decoded = try JSONDecoder().decode(
                HistoricalFindingBirthTime.self,
                from: JSONEncoder().encode(birthTime)
            )
            #expect(decoded == birthTime)
        }

        let malicious = #"{"secondsSince1970":1000,"nanoseconds":0,"future":true}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                HistoricalFindingBirthTime.self,
                from: Data(malicious.utf8)
            )
        }
    }

    @Test("A valid frame round trips without folding case or Unicode paths")
    func validFrameRoundTrips() throws {
        let root = try makeRootNode()
        let upperCase = try makeNode(
            endpointID: "endpoint-cache-upper",
            subjectID: "cache-upper",
            locationID: "location-cache-upper",
            parentSubjectID: "root",
            path: "/Fixtures/Cache",
            displayName: "Cache"
        )
        let lowerCase = try makeNode(
            endpointID: "endpoint-cache-lower",
            subjectID: "cache-lower",
            locationID: "location-cache-lower",
            parentSubjectID: "root",
            path: "/Fixtures/cache",
            displayName: "cache"
        )
        let unicode = try makeNode(
            endpointID: "endpoint-unicode",
            subjectID: "unicode",
            locationID: "location-unicode",
            parentSubjectID: "root",
            path: "/Fixtures/模型",
            displayName: "模型"
        )
        let frame = try makeFrame(nodes: [unicode, root, lowerCase, upperCase])

        let encoded = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(
            HistoricalFindingObservationFrame.self,
            from: encoded
        )

        #expect(decoded == frame)
        #expect(Set(decoded.nodes.map(\.path)) == [
            "/Fixtures",
            "/Fixtures/Cache",
            "/Fixtures/cache",
            "/Fixtures/模型",
        ])
    }
}

private enum FrameContextMismatch: String, CaseIterable {
    case scope = "Scope"
    case volume = "Volume"
    case mount = "Mount"
    case coverageEpoch = "CoverageEpoch"
    case metric = "Metric"
    case pathSemantics = "PathSemantics"
    case measurementSemantics = "MeasurementSemantics"
    case sequence = "Sequence"
}

private enum ClassificationFixture {
    case automatic
    case none
    case exact(VersionedAttributionDecision)
}

private func makeFrame(
    rootSubjectID: String = "root",
    rootPath: String = "/Fixtures",
    nodes: [HistoricalFindingNode]
) throws -> HistoricalFindingObservationFrame {
    try HistoricalFindingObservationFrame(
        rootSubjectID: SubjectID(rootSubjectID),
        rootPath: rootPath,
        nodes: nodes
    )
}

private func makeRootNode(
    endpointState: ObservationEndpointState? = nil,
    directChildrenCoverage: ObservationCoverage = .complete
) throws -> HistoricalFindingNode {
    try makeNode(
        endpointID: "endpoint-root",
        subjectID: "root",
        locationID: "location-root",
        parentSubjectID: nil,
        path: "/Fixtures",
        displayName: "Fixtures",
        state: endpointState,
        directChildrenCoverage: directChildrenCoverage
    )
}

private func makeNode(
    endpointID: String,
    subjectID: String,
    locationID: String,
    parentSubjectID: String?,
    path: String,
    displayName: String,
    scopeID: String = "scope-a",
    volumeID: String = "volume-a",
    mountGenerationID: String = "mount-a",
    coverageEpochID: String = "coverage-a",
    identityBasis: ObservationSubjectIdentityBasis = .normalizedPath,
    metric: StorageMetric = .logical,
    pathSemanticsVersion: Int = 1,
    measurementSemanticsVersion: Int = 1,
    sequence: Int64 = 1,
    state: ObservationEndpointState? = nil,
    directChildrenCoverage: ObservationCoverage = .complete,
    classification: ClassificationFixture = .automatic,
    stableIdentityEvidence: HistoricalFindingStableIdentityEvidence? = nil
) throws -> HistoricalFindingNode {
    let resolvedState = try state ?? .present(
        bytes: ByteCount(4_096),
        coverage: .complete
    )
    let endpoint = try ObservationEndpoint(
        id: ObservationEndpointID(endpointID),
        scopeID: ScopeID(scopeID),
        volumeID: ObservationVolumeID(volumeID),
        mountGenerationID: ObservationMountGenerationID(mountGenerationID),
        coverageEpochID: ObservationCoverageEpochID(coverageEpochID),
        subjectID: SubjectID(subjectID),
        identityBasis: identityBasis,
        locationID: ObservationLocationID(locationID),
        metric: metric,
        pathSemanticsVersion: ObservationSemanticsVersion(pathSemanticsVersion),
        measurementSemanticsVersion: ObservationSemanticsVersion(measurementSemanticsVersion),
        sequence: ObservationCommitSequence(sequence),
        observedAt: ObservationInstant(millisecondsSince1970: 1_000),
        state: resolvedState
    )

    let resolvedClassification: VersionedAttributionDecision?
    switch classification {
    case .automatic:
        if case .present = resolvedState {
            resolvedClassification = try makeClassificationDecision()
        } else {
            resolvedClassification = nil
        }
    case .none:
        resolvedClassification = nil
    case .exact(let decision):
        resolvedClassification = decision
    }

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

private func makeClassificationDecision() throws -> VersionedAttributionDecision {
    try VersionedAttributionDecision(
        catalogVersion: AttributionCatalogVersion(1),
        result: .unknown(.noMatchingRule)
    )
}
