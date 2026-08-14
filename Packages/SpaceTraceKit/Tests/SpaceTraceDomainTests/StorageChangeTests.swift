import Foundation
import Testing
@testable import SpaceTraceDomain

struct StorageChangeTests {
    @Test("Complete endpoints produce signed growth, decrease, and unchanged changes")
    func comparesCompleteMeasurements() throws {
        let baseline = try makeComparisonEndpoint(
            id: "baseline",
            sequence: 10,
            bytes: 100
        )

        let growth = try #require(
            try makeComparisonEndpoint(id: "growth", sequence: 11, bytes: 175)
                .compare(from: baseline)
                .change
        )
        #expect(growth.kind == .growth)
        #expect(growth.inclusiveDelta == .logical(bytes: 75))
        #expect(growth.baselineBytes?.value == 100)
        #expect(growth.comparisonBytes?.value == 175)

        let decrease = try #require(
            try makeComparisonEndpoint(id: "decrease", sequence: 12, bytes: 25)
                .compare(from: baseline)
                .change
        )
        #expect(decrease.kind == .decrease)
        #expect(decrease.inclusiveDelta == .logical(bytes: -75))

        let unchanged = try #require(
            try makeComparisonEndpoint(id: "unchanged", sequence: 13, bytes: 100)
                .compare(from: baseline)
                .change
        )
        #expect(unchanged.kind == .unchanged)
        #expect(unchanged.inclusiveDelta == .logical(bytes: 0))
    }

    @Test("Explicit absence produces candidates without treating unknown as zero")
    func comparesExplicitAbsence() throws {
        let absence = try absenceEvidence()
        let absentBaseline = try makeComparisonEndpoint(
            id: "absent-baseline",
            sequence: 20,
            state: .absent(absence)
        )
        let presentComparison = try makeComparisonEndpoint(
            id: "present-comparison",
            sequence: 21,
            bytes: 256
        )

        let appearance = try #require(
            presentComparison.compare(from: absentBaseline).change
        )
        #expect(appearance.kind == .appearanceCandidate)
        #expect(appearance.baselineBytes == nil)
        #expect(appearance.comparisonBytes?.value == 256)
        #expect(appearance.inclusiveDelta == .logical(bytes: 256))

        let absentComparison = try makeComparisonEndpoint(
            id: "absent-comparison",
            sequence: 22,
            state: .absent(absence)
        )
        let disappearance = try #require(
            absentComparison.compare(from: presentComparison).change
        )
        #expect(disappearance.kind == .disappearanceCandidate)
        #expect(disappearance.baselineBytes?.value == 256)
        #expect(disappearance.comparisonBytes == nil)
        #expect(disappearance.inclusiveDelta == .logical(bytes: -256))

        let stillAbsent = try #require(
            absentComparison.compare(from: absentBaseline).change
        )
        #expect(stillAbsent.kind == .unchanged)
        #expect(stillAbsent.inclusiveDelta == .logical(bytes: 0))
    }

    @Test("A complete stable identity produces only a relocation candidate")
    func producesStableRelocationCandidate() throws {
        let baseline = try makeComparisonEndpoint(
            id: "baseline",
            sequence: 30,
            observedAt: 2_000,
            bytes: 512,
            identityBasis: .stableFileSystemObject,
            location: "old-location"
        )
        let comparison = try makeComparisonEndpoint(
            id: "comparison",
            sequence: 31,
            observedAt: 1_000,
            bytes: 768,
            identityBasis: .stableFileSystemObject,
            location: "new-location"
        )

        let move = try #require(comparison.compare(from: baseline).change)
        #expect(move.kind == .relocationCandidate)
        #expect(move.sourceLocationID.rawValue == "old-location")
        #expect(move.destinationLocationID.rawValue == "new-location")
        #expect(move.inclusiveDelta == .logical(bytes: 256))
        #expect(move.baselineTime.millisecondsSince1970 == 2_000)
        #expect(move.comparisonTime.millisecondsSince1970 == 1_000)

        let pathBaseline = try makeComparisonEndpoint(
            id: "path-baseline",
            sequence: 40,
            bytes: 512,
            location: "old-location"
        )
        let pathComparison = try makeComparisonEndpoint(
            id: "path-comparison",
            sequence: 41,
            bytes: 512,
            location: "new-location"
        )
        #expect(
            pathComparison.compare(from: pathBaseline)
                == .incomparable(.locationChangedWithoutStableIdentity)
        )
    }

    @Test("Every measurement compatibility key is enforced independently")
    func rejectsCompatibilityMismatches() throws {
        let baseline = try makeComparisonEndpoint(id: "baseline", sequence: 50, bytes: 1)

        #expect(
            try makeComparisonEndpoint(id: "scope", scope: "scope-b", sequence: 51, bytes: 1)
                .compare(from: baseline) == .incomparable(.scopeMismatch)
        )
        #expect(
            try makeComparisonEndpoint(id: "volume", volume: "volume-b", sequence: 51, bytes: 1)
                .compare(from: baseline) == .incomparable(.volumeMismatch)
        )
        #expect(
            try makeComparisonEndpoint(id: "mount", mount: "mount-b", sequence: 51, bytes: 1)
                .compare(from: baseline) == .incomparable(.mountGenerationMismatch)
        )
        #expect(
            try makeComparisonEndpoint(id: "epoch", coverageEpoch: "epoch-b", sequence: 51, bytes: 1)
                .compare(from: baseline) == .incomparable(.coverageEpochMismatch)
        )
        #expect(
            try makeComparisonEndpoint(id: "subject", subject: "subject-b", sequence: 51, bytes: 1)
                .compare(from: baseline) == .incomparable(.subjectMismatch)
        )
        #expect(
            try makeComparisonEndpoint(
                id: "identity",
                sequence: 51,
                bytes: 1,
                identityBasis: .stableFileSystemObject
            ).compare(from: baseline) == .incomparable(.identityBasisMismatch)
        )
        #expect(
            try makeComparisonEndpoint(id: "metric", sequence: 51, bytes: 1, metric: .allocated)
                .compare(from: baseline) == .incomparable(.metricMismatch)
        )
        #expect(
            try makeComparisonEndpoint(id: "path", sequence: 51, bytes: 1, pathSemantics: 2)
                .compare(from: baseline) == .incomparable(.pathSemanticsMismatch)
        )
        #expect(
            try makeComparisonEndpoint(id: "measurement", sequence: 51, bytes: 1, measurementSemantics: 2)
                .compare(from: baseline) == .incomparable(.measurementSemanticsMismatch)
        )
        #expect(
            try makeComparisonEndpoint(id: "baseline", sequence: 51, bytes: 2)
                .compare(from: baseline) == .corrupt(.endpointIDReuse)
        )
        #expect(
            try makeComparisonEndpoint(
                id: "baseline",
                scope: "scope-b",
                sequence: 51,
                bytes: 2
            ).compare(from: baseline) == .corrupt(.endpointIDReuse)
        )
        #expect(
            try makeComparisonEndpoint(
                id: "baseline",
                sequence: 51,
                bytes: 2,
                metric: .allocated
            ).compare(from: baseline) == .corrupt(.endpointIDReuse)
        )
    }

    @Test("Partial, unknown, and non-increasing endpoints remain explicitly incomparable")
    func rejectsInsufficientEvidence() throws {
        let baseline = try makeComparisonEndpoint(id: "baseline", sequence: 60, bytes: 1)
        let partial = try makeComparisonEndpoint(
            id: "partial",
            sequence: 61,
            state: .present(bytes: ByteCount(2), coverage: .partial)
        )
        #expect(
            partial.compare(from: baseline)
                == .incomparable(.incompleteCoverage(baseline: .complete, comparison: .partial))
        )

        let unknown = try makeComparisonEndpoint(
            id: "unknown",
            sequence: 61,
            state: .unknown(.permissionDenied)
        )
        #expect(
            unknown.compare(from: baseline)
                == .incomparable(
                    .unavailable(baseline: nil, comparison: .permissionDenied)
                )
        )

        let unknownBaseline = try makeComparisonEndpoint(
            id: "unknown-baseline",
            sequence: 60,
            state: .unknown(.continuityGap)
        )
        let knownComparison = try makeComparisonEndpoint(
            id: "known-comparison",
            sequence: 61,
            bytes: 2
        )
        #expect(
            knownComparison.compare(from: unknownBaseline)
                == .incomparable(
                    .unavailable(baseline: .continuityGap, comparison: nil)
                )
        )

        let sameSequence = try makeComparisonEndpoint(id: "same", sequence: 60, bytes: 2)
        #expect(
            sameSequence.compare(from: baseline)
                == .incomparable(.nonIncreasingSequence(baseline: 60, comparison: 60))
        )
        let earlierSequence = try makeComparisonEndpoint(id: "earlier", sequence: 59, bytes: 2)
        #expect(
            earlierSequence.compare(from: baseline)
                == .incomparable(.nonIncreasingSequence(baseline: 60, comparison: 59))
        )
    }

    @Test("Location changes involving absence cannot be mislabeled as appearance or deletion")
    func rejectsLocationChangesWithoutTwoPresentEndpoints() throws {
        let absence = try absenceEvidence()
        let baseline = try makeComparisonEndpoint(
            id: "baseline",
            sequence: 70,
            state: .absent(absence),
            identityBasis: .stableFileSystemObject,
            location: "old-location"
        )
        let comparison = try makeComparisonEndpoint(
            id: "comparison",
            sequence: 71,
            bytes: 100,
            identityBasis: .stableFileSystemObject,
            location: "new-location"
        )

        #expect(
            comparison.compare(from: baseline)
                == .incomparable(.locationChangedWithoutTwoPresentEndpoints)
        )
    }

    @Test("Comparable and incomparable outcomes round trip as durable typed evidence")
    func roundTripsOutcomes() throws {
        let baseline = try makeComparisonEndpoint(id: "baseline", sequence: 80, bytes: 10)
        let comparison = try makeComparisonEndpoint(id: "comparison", sequence: 81, bytes: 20)
        let comparable = comparison.compare(from: baseline)
        let incomparable = try makeComparisonEndpoint(
            id: "unknown",
            sequence: 81,
            state: .unknown(.volumeUnavailable)
        ).compare(from: baseline)
        let corrupt = try makeComparisonEndpoint(
            id: "baseline",
            sequence: 82,
            bytes: 30
        ).compare(from: baseline)

        for outcome in [comparable, incomparable, corrupt] {
            let encoded = try JSONEncoder().encode(outcome)
            let decoded = try JSONDecoder().decode(
                ObservationComparisonOutcome.self,
                from: encoded
            )
            #expect(decoded == outcome)
        }
    }

    @Test("Decoding rejects changes that bypass comparison invariants")
    func decodingRevalidatesChanges() throws {
        let baseline = try makeComparisonEndpoint(id: "baseline", sequence: 90, bytes: 10)
        let comparison = try makeComparisonEndpoint(id: "comparison", sequence: 91, bytes: 20)
        let change = try #require(comparison.compare(from: baseline).change)

        #expect(throws: DecodingError.self) {
            try decodeMutated(change) { object in
                object["comparisonSequence"] = 90
            }
        }
        #expect(throws: DecodingError.self) {
            try decodeMutated(change) { object in
                object["kind"] = StorageChangeKind.relocationCandidate.rawValue
            }
        }
        #expect(throws: DecodingError.self) {
            try decodeMutated(change) { object in
                object["inclusiveDelta"] = try encodedJSONObject(
                    StorageDelta.allocated(bytes: 10)
                )
            }
        }
        #expect(throws: DecodingError.self) {
            try decodeMutated(change) { object in
                object["inclusiveDelta"] = try encodedJSONObject(
                    StorageDelta.logical(bytes: 999)
                )
            }
        }
        #expect(throws: DecodingError.self) {
            try decodeMutated(change) { object in
                object["comparisonEndpointID"] = "baseline"
            }
        }
        #expect(throws: DecodingError.self) {
            try decodeMutated(change) { object in
                object["destinationLocationID"] = "different-location"
            }
        }
        #expect(throws: DecodingError.self) {
            try decodeMutated(change) { object in
                object["comparisonBytes"] = 999
            }
        }

        let relocationBaseline = try makeComparisonEndpoint(
            id: "relocation-baseline",
            sequence: 92,
            bytes: 10,
            identityBasis: .stableFileSystemObject,
            location: "old-location"
        )
        let relocationComparison = try makeComparisonEndpoint(
            id: "relocation-comparison",
            sequence: 93,
            bytes: 10,
            identityBasis: .stableFileSystemObject,
            location: "new-location"
        )
        let relocation = try #require(
            relocationComparison.compare(from: relocationBaseline).change
        )
        #expect(throws: DecodingError.self) {
            try decodeMutated(relocation) { object in
                object["identityBasis"] = ObservationSubjectIdentityBasis.normalizedPath.rawValue
            }
        }
    }

    @Test("Impossible incomparability reasons cannot become durable evidence")
    func rejectsImpossibleIncomparabilityPayloads() {
        let invalidReasons: [ObservationIncomparability] = [
            .nonIncreasingSequence(baseline: 1, comparison: 2),
            .incompleteCoverage(baseline: .complete, comparison: .complete),
            .unavailable(baseline: nil, comparison: nil),
        ]

        for reason in invalidReasons {
            #expect(throws: EncodingError.self) {
                try JSONEncoder().encode(reason)
            }
        }
    }
}

private extension ObservationComparisonOutcome {
    var change: StorageChange? {
        guard case .comparable(let change) = self else { return nil }
        return change
    }
}

private func absenceEvidence() throws -> ParentAbsenceReference {
    try ParentAbsenceReference(
        parentEndpointID: ObservationEndpointID("parent-endpoint"),
        parentSubjectID: SubjectID("parent-subject")
    )
}

private func decodeMutated(
    _ change: StorageChange,
    mutate: (inout [String: Any]) throws -> Void
) throws -> StorageChange {
    let data = try JSONEncoder().encode(change)
    var object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    try mutate(&object)
    let mutatedData = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(StorageChange.self, from: mutatedData)
}

private func encodedJSONObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

private func makeComparisonEndpoint(
    id: String,
    scope: String = "scope-a",
    volume: String = "volume-a",
    mount: String = "mount-a",
    coverageEpoch: String = "epoch-a",
    subject: String = "subject-a",
    sequence: Int64,
    observedAt: Int64 = 1_000,
    bytes: Int64? = nil,
    state: ObservationEndpointState? = nil,
    identityBasis: ObservationSubjectIdentityBasis = .normalizedPath,
    location: String = "location-a",
    metric: StorageMetric = .logical,
    pathSemantics: Int = 1,
    measurementSemantics: Int = 1
) throws -> ObservationEndpoint {
    let resolvedState: ObservationEndpointState
    if let state {
        resolvedState = state
    } else {
        resolvedState = .present(bytes: try ByteCount(bytes ?? 0), coverage: .complete)
    }

    return try ObservationEndpoint(
        id: ObservationEndpointID(id),
        scopeID: ScopeID(scope),
        volumeID: ObservationVolumeID(volume),
        mountGenerationID: ObservationMountGenerationID(mount),
        coverageEpochID: ObservationCoverageEpochID(coverageEpoch),
        subjectID: SubjectID(subject),
        identityBasis: identityBasis,
        locationID: ObservationLocationID(location),
        metric: metric,
        pathSemanticsVersion: ObservationSemanticsVersion(pathSemantics),
        measurementSemanticsVersion: ObservationSemanticsVersion(measurementSemantics),
        sequence: ObservationCommitSequence(sequence),
        observedAt: ObservationInstant(millisecondsSince1970: observedAt),
        state: resolvedState
    )
}
