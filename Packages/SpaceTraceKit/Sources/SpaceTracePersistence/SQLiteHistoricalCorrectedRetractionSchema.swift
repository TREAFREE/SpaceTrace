import Foundation
import SQLite3

/// Additive schema-v13 lane for evidence invalidation of findings emitted by
/// correcting projections. The frozen schema-v12 object graph is not edited.
enum SQLiteHistoricalCorrectedRetractionSchema {
    static let frozenObjectNames: Set<String> = [
        "historical_corrected_finding_retraction",
        "historical_corrected_retraction_validate_target",
        "historical_corrected_retraction_immutable_update",
    ]

    /// SHA-256 over the complete frozen schema-v13 object graph.
    static let frozenSchemaDigest = Data([
        0xCD, 0x10, 0xE2, 0x39, 0xCC, 0x60, 0x67, 0xA7,
        0x7C, 0x4E, 0x51, 0xA0, 0xD8, 0x62, 0xAD, 0x69,
        0x42, 0xC4, 0x06, 0xB2, 0x4A, 0x2C, 0xA2, 0x96,
        0x23, 0x04, 0xBD, 0x77, 0xFF, 0xBC, 0x49, 0xA4,
    ])

    static func installFrozenV13(on database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, schemaSQL, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            if let errorMessage { sqlite3_free(errorMessage) }
            throw SQLiteHistoricalCorrectedRetractionSchemaError.sqlite
        }
    }

    private static let schemaSQL = #"""
    CREATE TABLE historical_corrected_finding_retraction (
        corrected_retraction_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        request_format_version INTEGER NOT NULL CHECK(request_format_version=1),
        request_id BLOB NOT NULL UNIQUE CHECK(typeof(request_id)='blob' AND length(request_id)=16),
        canonical_request_sha256 BLOB NOT NULL CHECK(typeof(canonical_request_sha256)='blob' AND length(canonical_request_sha256)=32),
        retracted_corrected_finding_id INTEGER NOT NULL UNIQUE REFERENCES historical_corrected_finding(corrected_finding_id) ON DELETE RESTRICT,
        expected_draft_sha256 BLOB NOT NULL CHECK(typeof(expected_draft_sha256)='blob' AND length(expected_draft_sha256)=32),
        reason_code INTEGER NOT NULL CHECK(reason_code=1),
        committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0),
        expires_at_ms INTEGER NOT NULL CHECK(expires_at_ms >= 0 AND committed_at_ms<=expires_at_ms)
    );

    CREATE TRIGGER historical_corrected_retraction_validate_target
    BEFORE INSERT ON historical_corrected_finding_retraction BEGIN
        SELECT CASE WHEN NOT EXISTS(
            SELECT 1
            FROM historical_corrected_finding finding
            JOIN historical_correcting_projection projection
              ON projection.correcting_projection_id=finding.correcting_projection_id
            JOIN historical_projection_correction_checkpoint checkpoint
              ON checkpoint.correcting_projection_id=projection.correcting_projection_id
            WHERE finding.corrected_finding_id=NEW.retracted_corrected_finding_id
              AND finding.draft_sha256=NEW.expected_draft_sha256
              AND finding.expires_at_ms=NEW.expires_at_ms
              AND projection.expires_at_ms=NEW.expires_at_ms
              AND NOT EXISTS(
                  SELECT 1
                  FROM historical_projection_correction_work successor_work
                  JOIN historical_correcting_projection successor
                    ON successor.work_id=successor_work.work_id
                  JOIN historical_projection_correction_checkpoint successor_checkpoint
                    ON successor_checkpoint.correcting_projection_id=
                       successor.correcting_projection_id
                  WHERE successor_work.predecessor_correcting_projection_id=
                        projection.correcting_projection_id
              )
        ) THEN RAISE(ABORT,'corrected retraction target mismatch') END;
    END;

    CREATE TRIGGER historical_corrected_retraction_immutable_update
    BEFORE UPDATE ON historical_corrected_finding_retraction BEGIN
        SELECT RAISE(ABORT,'immutable historical corrected finding retraction');
    END;
    """#
}

enum SQLiteHistoricalCorrectedRetractionSchemaError: Error {
    case sqlite
}
