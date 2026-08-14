import SpaceTraceApplication
import SpaceTraceDomain
import Testing

struct ReconciliationRevisionPublicationTests {
    @Test("A historical commit exposes a stable canonical revision receipt")
    func commitReceiptPreservesRevisionIdentity() throws {
        let hourlyKey = try publicationRevisionKey(bucket: .hourly)
        let dailyKey = try publicationRevisionKey(bucket: .daily)
        let daily = try publicationRevision(id: 4, key: dailyKey)
        let hourly = try publicationRevision(id: 3, key: hourlyKey)

        let commit = HistoricalCalibrationCommit(
            disposition: .newlyCommitted,
            logical: try HistoricalObservationFrameCommit(
                sequence: ObservationCommitSequence(1),
                rootEndpointID: ObservationEndpointID("logical"),
                endpointCount: 1
            ),
            allocated: try HistoricalObservationFrameCommit(
                sequence: ObservationCommitSequence(2),
                rootEndpointID: ObservationEndpointID("allocated"),
                endpointCount: 1
            ),
            reconciliationRevisions: [daily, hourly]
        )

        #expect(commit.reconciliationRevisions.map(\.id.rawValue) == [3, 4])
        #expect(commit.reconciliationRevisions.map(\.key.bucket) == [.hourly, .daily])
    }
}

private func publicationRevisionKey(
    bucket: DirectoryHistoryBucket
) throws -> ReconciliationRevisionKey {
    try ReconciliationRevisionKey(
        scopeID: WatchedScopeID("scope"),
        streamID: EventStreamID("stream"),
        subjectID: SubjectID("subject"),
        locationID: ObservationLocationID("location"),
        bucket: bucket,
        bucketStart: ObservationInstant(millisecondsSince1970: 0)
    )
}

private func publicationRevision(
    id: Int64,
    key: ReconciliationRevisionKey
) throws -> ReconciliationRevision {
    try ReconciliationRevision(
        id: ReconciliationRevisionID(id),
        sequence: ReconciliationRevisionSequence(id),
        key: key,
        predecessor: nil,
        scanRunID: CalibrationRunID("00000000-0000-0000-0000-000000000001"),
        dirtyRevision: DirtyRegionRevision(1),
        observedAt: ObservationInstant(millisecondsSince1970: 1),
        logicalBytes: ByteCount(1),
        allocatedBytes: ByteCount(1),
        descendantCount: 0,
        payloadDigest: ReconciliationRevisionDigest(bytes: Array(repeating: 1, count: 32))
    )
}
