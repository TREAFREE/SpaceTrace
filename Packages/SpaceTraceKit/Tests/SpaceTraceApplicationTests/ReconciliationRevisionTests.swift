import SpaceTraceApplication
import SpaceTraceDomain
import Testing

struct ReconciliationRevisionTests {
    @Test("Revision scalar identities reject zero IDs and malformed digests")
    func scalarValidation() throws {
        #expect(throws: ReconciliationRevisionModelError.invalidRecordID(0)) {
            try ReconciliationRevisionID(0)
        }
        #expect(throws: ReconciliationRevisionModelError.invalidSequence(0)) {
            try ReconciliationRevisionSequence(0)
        }
        #expect(throws: ReconciliationRevisionModelError.invalidDigestLength(31)) {
            try ReconciliationRevisionDigest(bytes: Array(repeating: 1, count: 31))
        }
        #expect(try ReconciliationRevisionDigest(bytes: Array(repeating: 0, count: 32)).bytes.count == 32)
    }

    @Test("Bucket keys require exact UTC bucket alignment")
    func bucketAlignment() throws {
        #expect(throws: ReconciliationRevisionModelError.misalignedBucketStart) {
            try revisionKey(bucketStartMilliseconds: 3_600_001)
        }

        let hourly = try revisionKey(bucketStartMilliseconds: 3_600_000)
        #expect(hourly.bucket == .hourly)
        #expect(hourly.bucketStart.millisecondsSince1970 == 3_600_000)
    }

    @Test("A successor preserves the exact bucket key and increases only durable order")
    func successorValidationAndClockRollback() throws {
        let key = try revisionKey(bucketStartMilliseconds: 3_600_000)
        let first = try revision(
            id: 1,
            sequence: 10,
            key: key,
            observedAtMilliseconds: 20_000,
            predecessor: nil
        )
        let second = try revision(
            id: 2,
            sequence: 11,
            key: key,
            observedAtMilliseconds: 10_000,
            predecessor: first.reference
        )

        #expect(second.predecessorID == first.id)
        #expect(second.observedAt < first.observedAt)

        #expect(throws: ReconciliationRevisionModelError.predecessorRecordReused) {
            try revision(
                id: 1,
                sequence: 11,
                key: key,
                observedAtMilliseconds: 30_000,
                predecessor: first.reference
            )
        }
        #expect(throws: ReconciliationRevisionModelError.nonIncreasingSequence) {
            try revision(
                id: 2,
                sequence: 10,
                key: key,
                observedAtMilliseconds: 30_000,
                predecessor: first.reference
            )
        }
        #expect(throws: ReconciliationRevisionModelError.predecessorKeyMismatch) {
            try revision(
                id: 2,
                sequence: 11,
                key: revisionKey(bucketStartMilliseconds: 7_200_000),
                observedAtMilliseconds: 30_000,
                predecessor: first.reference
            )
        }
    }

    @Test("Opaque UTF-8 identities do not collapse canonically equivalent keys")
    func binaryIdentity() throws {
        let composed = try revisionKey(
            bucketStartMilliseconds: 0,
            scopeID: "scope-é",
            streamID: "stream-é"
        )
        let decomposed = try revisionKey(
            bucketStartMilliseconds: 0,
            scopeID: "scope-e\u{301}",
            streamID: "stream-e\u{301}"
        )

        #expect(composed != decomposed)
        #expect(Set([composed, decomposed]).count == 2)
    }

    @Test("Complete revision measurements reject negative descendant counts")
    func negativeDescendantCount() throws {
        #expect(throws: ReconciliationRevisionModelError.invalidDescendantCount(-1)) {
            _ = try ReconciliationRevision(
                id: ReconciliationRevisionID(1),
                sequence: ReconciliationRevisionSequence(1),
                key: revisionKey(bucketStartMilliseconds: 0),
                predecessor: nil,
                scanRunID: CalibrationRunID("00000000-0000-0000-0000-000000000001"),
                dirtyRevision: DirtyRegionRevision(1),
                observedAt: ObservationInstant(millisecondsSince1970: 1),
                logicalBytes: ByteCount(1),
                allocatedBytes: ByteCount(1),
                descendantCount: -1,
                payloadDigest: ReconciliationRevisionDigest(
                    bytes: Array(repeating: 1, count: 32)
                )
            )
        }
    }
}

private func revisionKey(
    bucketStartMilliseconds: Int64,
    scopeID: String = "scope-a",
    streamID: String = "stream-a"
) throws -> ReconciliationRevisionKey {
    try ReconciliationRevisionKey(
        scopeID: WatchedScopeID(scopeID),
        streamID: EventStreamID(streamID),
        subjectID: SubjectID("subject-a"),
        locationID: ObservationLocationID("location-a"),
        bucket: .hourly,
        bucketStart: ObservationInstant(millisecondsSince1970: bucketStartMilliseconds)
    )
}

private func revision(
    id: Int64,
    sequence: Int64,
    key: ReconciliationRevisionKey,
    observedAtMilliseconds: Int64,
    predecessor: ReconciliationRevisionReference?
) throws -> ReconciliationRevision {
    try ReconciliationRevision(
        id: ReconciliationRevisionID(id),
        sequence: ReconciliationRevisionSequence(sequence),
        key: key,
        predecessor: predecessor,
        scanRunID: CalibrationRunID("00000000-0000-0000-0000-00000000000\(id)"),
        dirtyRevision: DirtyRegionRevision(UInt64(sequence)),
        observedAt: ObservationInstant(millisecondsSince1970: observedAtMilliseconds),
        logicalBytes: ByteCount(sequence),
        allocatedBytes: ByteCount(sequence),
        descendantCount: sequence,
        payloadDigest: ReconciliationRevisionDigest(
            bytes: Array(repeating: UInt8(id), count: 32)
        )
    )
}
