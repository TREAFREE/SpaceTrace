import Foundation
import SQLite3

/// Persistence-owned validation boundary for schema-v12 correction evidence.
///
/// Mutation methods intentionally arrive in later slices. Migration can only
/// install an empty append-only lane and validate its exact object graph; it
/// cannot fabricate revisions or correcting projections from legacy rows.
enum SQLiteHistoricalCorrectionRepository {
    static func validateInstalledSchema(database: OpaquePointer) throws {
        try SQLiteHistoricalFindingCodec.validateInstalledV12(
            database: database,
            frozenSchemaDigest: SQLiteHistoricalCorrectionSchema.frozenSchemaDigest
        )
    }
}
