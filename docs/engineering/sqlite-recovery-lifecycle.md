# SQLite Recovery Lifecycle

SpaceTrace treats startup database failures as recoverable incidents, never as permission to create a replacement database.

1. Before every migration from a released schema, SQLite Online Backup writes a complete temporary database in the database directory. A same-filesystem `rename(2)` publishes it atomically as `SpaceTrace.sqlite.pre-migration-vN.sqlite`.
2. A successful migration and repository startup removes that backup. A failed migration keeps it.
3. Startup validates the main database header and WAL framing before SQLite may mutate either artifact.
4. On migration, corruption, disk-full, unsupported-schema, or unknown startup failure, the main database, WAL, SHM, and migration backup are copied into a permission-restricted `Recovery/<incident-id>` directory. The source files are not deleted or reset.
5. Recovery mode prefers the immutable migration backup, then an immutable main-file snapshot. Its SQLite connection is opened read-only with `query_only`; the application does not start scanning or monitoring.

The manifest contains reason, time, and artifact file names only. It never records absolute user paths. Current structural WAL validation catches truncated and malformed framing; deeper page-level diagnosis belongs to an explicit offline repair tool.

Validation lives in `SQLiteDatabaseRecoveryTests`: atomic backup retention/removal, byte-preserving main/WAL isolation, immutable fallback selection, and rejected writes.
