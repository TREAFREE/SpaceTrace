import SpaceTraceApplication
import SpaceTraceDomain
import Testing

@Suite("Versioned historical finding identities")
struct HistoricalFindingVersionedIdentityTests {
    @Test("Corrected finding identifiers require a positive database value")
    func correctedFindingIDValidation() throws {
        #expect(
            throws: HistoricalFindingVersionedIdentityError
                .invalidCorrectedFindingRecordID(0)
        ) {
            _ = try HistoricalCorrectedFindingRecordID(0)
        }
        #expect(
            throws: HistoricalFindingVersionedIdentityError
                .invalidCorrectedFindingRecordID(-1)
        ) {
            _ = try HistoricalCorrectedFindingRecordID(-1)
        }
        #expect(try HistoricalCorrectedFindingRecordID(1).rawValue == 1)
    }

    @Test("Colliding raw projection identifiers stay distinct and sort by source")
    func projectionNamespacesRemainDistinct() throws {
        let original = HistoricalProjectionVersionID.original(
            try HistoricalProjectionRecordID(1)
        )
        let correcting = HistoricalProjectionVersionID.correcting(
            try HistoricalCorrectingProjectionRecordID(1)
        )

        #expect(original != correcting)
        #expect(Set([original, correcting]).count == 2)
        #expect([correcting, original].sorted() == [original, correcting])
    }

    @Test("Colliding raw finding identifiers stay distinct and sort by source then ID")
    func findingNamespacesRemainDistinct() throws {
        let originalOne = HistoricalFindingVersionID.original(
            try HistoricalFindingRecordID(1)
        )
        let originalTwo = HistoricalFindingVersionID.original(
            try HistoricalFindingRecordID(2)
        )
        let correctedOne = HistoricalFindingVersionID.corrected(
            try HistoricalCorrectedFindingRecordID(1)
        )

        #expect(originalOne != correctedOne)
        #expect(Set([originalOne, correctedOne]).count == 2)
        #expect(
            [correctedOne, originalTwo, originalOne].sorted()
                == [originalOne, originalTwo, correctedOne]
        )
    }

    @Test("Only a typed integrity audit can authorize corrected evidence invalidation")
    func correctedInvalidationAuthorization() throws {
        let findingID = try HistoricalCorrectedFindingRecordID(7)
        let projectionID = try HistoricalCorrectingProjectionRecordID(3)
        let digest = try HistoricalEvidenceDigest(bytes: Array(repeating: 0xA5, count: 32))
        let audit = try HistoricalCorrectedFindingIntegrityAuditRecord(
            findingID: findingID,
            projectionID: projectionID,
            draftSHA256: digest,
            retraction: nil
        )
        let requestID = try HistoricalRetractionRequestID(bytes: Array(0..<16))
        let command = try HistoricalCorrectedFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: requestID,
                failure: .projectionIntegrityViolation,
                storedAuditRecord: audit
            )

        #expect(command.requestID == requestID)
        #expect(command.findingID == findingID)
        #expect(command.expectedDraftSHA256 == digest)

        let retraction = try HistoricalCorrectedFindingRetractionRecord(
            recordID: HistoricalCorrectedRetractionRecordID(1),
            requestID: requestID,
            findingID: findingID,
            reason: .evidenceInvalidated,
            committedAt: ObservationInstant(millisecondsSince1970: 10),
            expiresAt: ObservationInstant(millisecondsSince1970: 20)
        )
        let retractedAudit = try HistoricalCorrectedFindingIntegrityAuditRecord(
            findingID: findingID,
            projectionID: projectionID,
            draftSHA256: digest,
            retraction: retraction
        )
        #expect(
            throws: HistoricalFindingVersionedIdentityError.correctedFindingAlreadyRetracted
        ) {
            _ = try HistoricalCorrectedFindingIntegrityReconciliationAuthorizer
                .authorizeEvidenceInvalidation(
                    requestID: requestID,
                    failure: .ledgerIntegrityViolation,
                    storedAuditRecord: retractedAudit
                )
        }
    }
}
