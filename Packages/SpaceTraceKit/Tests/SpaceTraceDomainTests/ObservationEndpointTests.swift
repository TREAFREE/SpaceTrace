import Foundation
import Testing
@testable import SpaceTraceDomain

struct ObservationEndpointTests {
    @Test("An immutable present endpoint retains every compatibility key")
    func retainsCompatibilityEvidence() throws {
        let expectedScope = try ScopeID("scope-a")
        let expectedSubject = try SubjectID("subject-a")
        let expectedTime = try ObservationInstant(millisecondsSince1970: 1_000)
        let expectedBytes = try ByteCount(4_096)
        let endpoint = try ObservationEndpoint(
            id: ObservationEndpointID("endpoint-2"),
            scopeID: expectedScope,
            volumeID: ObservationVolumeID("volume-a"),
            mountGenerationID: ObservationMountGenerationID("mount-a"),
            coverageEpochID: ObservationCoverageEpochID("coverage-a"),
            subjectID: expectedSubject,
            identityBasis: .stableFileSystemObject,
            locationID: ObservationLocationID("location-a"),
            metric: .allocated,
            pathSemanticsVersion: ObservationSemanticsVersion(1),
            measurementSemanticsVersion: ObservationSemanticsVersion(2),
            sequence: ObservationCommitSequence(2),
            observedAt: expectedTime,
            state: .present(bytes: expectedBytes, coverage: .complete)
        )

        #expect(endpoint.id.rawValue == "endpoint-2")
        #expect(endpoint.scopeID == expectedScope)
        #expect(endpoint.volumeID.rawValue == "volume-a")
        #expect(endpoint.mountGenerationID.rawValue == "mount-a")
        #expect(endpoint.coverageEpochID.rawValue == "coverage-a")
        #expect(endpoint.subjectID == expectedSubject)
        #expect(endpoint.identityBasis == .stableFileSystemObject)
        #expect(endpoint.locationID.rawValue == "location-a")
        #expect(endpoint.metric == .allocated)
        #expect(endpoint.pathSemanticsVersion.rawValue == 1)
        #expect(endpoint.measurementSemanticsVersion.rawValue == 2)
        #expect(endpoint.sequence.rawValue == 2)
        #expect(endpoint.observedAt == expectedTime)
        #expect(endpoint.state == .present(bytes: expectedBytes, coverage: .complete))
    }

    @Test("Endpoint evidence keys reject empty, padded, and null-containing values")
    func rejectsInvalidEvidenceKeys() {
        for value in ["", " ", " padded", "padded ", "bad\0key"] {
            #expect(throws: ObservationEndpointValidationError.invalidEndpointID) {
                try ObservationEndpointID(value)
            }
            #expect(throws: ObservationEndpointValidationError.invalidVolumeID) {
                try ObservationVolumeID(value)
            }
            #expect(throws: ObservationEndpointValidationError.invalidMountGenerationID) {
                try ObservationMountGenerationID(value)
            }
            #expect(throws: ObservationEndpointValidationError.invalidCoverageEpochID) {
                try ObservationCoverageEpochID(value)
            }
            #expect(throws: ObservationEndpointValidationError.invalidLocationID) {
                try ObservationLocationID(value)
            }
        }
    }

    @Test("Commit sequences and semantics versions are strictly positive")
    func rejectsNonPositiveCounters() {
        for value in [Int64.min, -1, 0] {
            #expect(throws: ObservationEndpointValidationError.invalidCommitSequence(value)) {
                try ObservationCommitSequence(value)
            }
        }
        for value in [Int.min, -1, 0] {
            #expect(throws: ObservationEndpointValidationError.invalidSemanticsVersion(value)) {
                try ObservationSemanticsVersion(value)
            }
        }
    }

    @Test("Unknown is a distinct state and cannot be smuggled into a present endpoint")
    func unknownIsNotPresent() throws {
        let bytes = try ByteCount(0)

        #expect(throws: ObservationEndpointValidationError.presentCannotUseUnknownCoverage) {
            try makeEndpoint(state: .present(bytes: bytes, coverage: .unknown))
        }

        let endpoint = try makeEndpoint(state: .unknown(.permissionDenied))
        #expect(endpoint.state == .unknown(.permissionDenied))
    }

    @Test("Explicit absence retains a parent reference without claiming frame proof")
    func retainsAbsenceEvidence() throws {
        let parentEndpointID = try ObservationEndpointID("parent-endpoint")
        let parentSubjectID = try SubjectID("parent-subject")
        let evidence = ParentAbsenceReference(
            parentEndpointID: parentEndpointID,
            parentSubjectID: parentSubjectID
        )

        let endpoint = try makeEndpoint(state: .absent(evidence))

        #expect(endpoint.state == .absent(evidence))
    }

    @Test("An absence reference cannot point back to the absent endpoint or subject")
    func rejectsSelfReferentialAbsence() throws {
        #expect(throws: ObservationEndpointValidationError.invalidParentAbsenceReference) {
            try makeEndpoint(
                state: .absent(
                    ParentAbsenceReference(
                        parentEndpointID: ObservationEndpointID("endpoint-a"),
                        parentSubjectID: SubjectID("parent-subject")
                    )
                )
            )
        }
        #expect(throws: ObservationEndpointValidationError.invalidParentAbsenceReference) {
            try makeEndpoint(
                state: .absent(
                    ParentAbsenceReference(
                        parentEndpointID: ObservationEndpointID("parent-endpoint"),
                        parentSubjectID: SubjectID("subject-a")
                    )
                )
            )
        }
    }

    @Test("Durable endpoint values round trip and decoding revalidates counters")
    func roundTripsAndRevalidates() throws {
        let endpoint = try makeEndpoint(
            state: .present(bytes: ByteCount(8_192), coverage: .partial)
        )

        let encoded = try JSONEncoder().encode(endpoint)
        let decoded = try JSONDecoder().decode(ObservationEndpoint.self, from: encoded)
        #expect(decoded == endpoint)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ObservationCommitSequence.self,
                from: Data("0".utf8)
            )
        }
    }
}

private func makeEndpoint(
    state: ObservationEndpointState,
    identityBasis: ObservationSubjectIdentityBasis = .normalizedPath,
    location: String = "location-a"
) throws -> ObservationEndpoint {
    try ObservationEndpoint(
        id: ObservationEndpointID("endpoint-a"),
        scopeID: ScopeID("scope-a"),
        volumeID: ObservationVolumeID("volume-a"),
        mountGenerationID: ObservationMountGenerationID("mount-a"),
        coverageEpochID: ObservationCoverageEpochID("coverage-a"),
        subjectID: SubjectID("subject-a"),
        identityBasis: identityBasis,
        locationID: ObservationLocationID(location),
        metric: .logical,
        pathSemanticsVersion: ObservationSemanticsVersion(1),
        measurementSemanticsVersion: ObservationSemanticsVersion(1),
        sequence: ObservationCommitSequence(1),
        observedAt: ObservationInstant(millisecondsSince1970: 1),
        state: state
    )
}
