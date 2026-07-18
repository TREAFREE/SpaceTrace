# ADR-004: SQLite persistence, GRDB adapter, and bounded 30-day retention

## Status

Proposed — SQLite is selected; GRDB adoption is subject to dependency/licence/build validation in the architecture spike.

Date: 2026-07-18

## Context

SpaceTrace needs durable local state for watch scopes, volume identities, FSEvents cursors, dirty work, interrupted scan recovery, current directory aggregates, time-bucketed observations, findings, and schema migrations. The cursor protocol requires atomic transactions across event work and checkpoints. Queries must remain responsive while scans write batches.

The data contains sensitive local paths and can grow with filesystem cardinality. Keeping every file at every observation would cause the diagnostic database itself to become a storage problem. Conversely, retaining only aggregate totals would prevent users from understanding changes over time.

The application has no backend, multi-user database, or cross-device synchronization requirement.

## Decision

1. Use one SQLite database in the user's SpaceTrace Application Support directory as the durable source of truth.
2. Enable WAL mode, foreign keys, bounded busy timeout, `synchronous=NORMAL` for routine operation, and an idle checkpoint policy. Migrations and critical recovery transitions may temporarily use stronger synchronization.
3. Use one logical database writer behind an actor. Permit consistent read snapshots through a pool so UI queries do not share mutable persistence state with scan code.
4. Implement persistence through repository/transaction ports. GRDB is the proposed adapter because it provides typed records, migrations, pooling, and transaction primitives; no GRDB type crosses into domain/application modules.
5. Use staging tables for long scans and short atomic finalization transactions. Incomplete stages never appear as current truth.
6. Persist all directory aggregates but only selected files: pinned, classified roots, top contributors, or files above the default large-file threshold. Do not retain every small file indefinitely.
7. Apply a **30-day maximum default for path-level history**: hourly samples for 7 days, daily samples/path-bearing findings/deleted-node history through day 30, then transactional deletion. Only the minimum path-free gap/health marker needed to explain a discontinuity may remain after expiry.
8. Path-bearing dirty work normally disappears after safe finalization. If it remains unresolved at day 30, replace it with a path-free scope-level `requiresCalibration` marker, delete the path, and perform a safe calibration when observation resumes.
9. Keep the default-retention database below 250 MB for the PRD benchmark workload. Compaction removes expired path-level history and expired deleted nodes before other optional data. It never silently deletes the active baseline or the fact that reconciliation is required.
10. Schema migrations are ordered, checksummed, forward-only, and tested from every released fixture. Migration failure enters read-only recovery rather than silently replacing the database.
11. Protect the database directory/file with user-only modes, exclude it from SpaceTrace scans, and never include it in diagnostic export.
12. Any option beyond 30 days requires a future RFC/PRD update. It must be user-visible, clearable, explicitly opt-in, default-off, and disclose estimated privacy/storage cost.
13. Schema v5 stores user-selected watched-scope bookmarks as bounded opaque BLOBs together with the exact authorized root and volume UUID. Platform resolution, not persistence, derives the current mount path and activates access.

## Options considered

| Option | Benefits | Costs / failure modes | Assessment |
| --- | --- | --- | --- |
| SQLite + GRDB adapter | ACID, WAL, migrations, concurrent reads, mature Swift API | Third-party dependency and supply-chain review | Selected pending adapter validation |
| Raw SQLite C API | Minimal dependencies and complete control | Significant statement/migration/concurrency boilerplate; higher defect risk | Viable fallback |
| Core Data / SwiftData | Apple-integrated object graph and UI tooling | Less explicit transaction/cursor semantics; migration/debugging complexity; framework coupling | Rejected for core journal protocol |
| JSON/plist files | Easy inspection | Weak atomic multi-entity updates, poor queries, corruption/rewrite risk | Rejected |
| Embedded analytical DB | Powerful columnar history queries | Larger dependency/footprint and weak fit for durable work queue | Rejected |
| Store every file observation | Maximum drill-down | Unbounded DB and privacy footprint | Rejected |
| Store only top-level totals | Small database | Cannot explain changes or recover dirty subtrees well | Rejected |

## Consequences

### Positive

- Cursor and dirty-work atomicity can be expressed and tested directly.
- WAL supports responsive cached UI reads during bounded scan writes.
- A database backup and fixture-based migration strategy is practical.
- Directory-first, 30-day bounded retention aligns storage cost with product value and privacy baseline.

### Negative and accepted trade-offs

- SQLite/GRDB schema design becomes a durable compatibility contract.
- WAL/checkpoint/vacuum need explicit energy and disk-full behavior.
- Selected-file persistence means deep file detail may require an on-demand rescan.
- Paths remain readable to other processes running as the same user; SQLCipher is not included in MVP.

### Guardrails

- Cursor/dirty and scan-finalization transactions have dedicated fault-injection tests.
- All timestamps are UTC Unix milliseconds; FSEvent IDs retain the full UInt64 range in big-endian blobs.
- Byte metrics use checked signed 64-bit values and typed wrappers; overflow becomes an error/unknown value.
- Migration code cannot silently drop an unknown column/table or recreate the database.
- Retention is deterministic, observable, and testable against a fixed clock.
- The 250 MB value is a release gate for the benchmark workload, not permission to erase active state on a larger real scope. Settings exposes actual size and the estimated effect of retention.
- The app pauses nonessential scans before compaction when its own database growth threatens available disk space.
- Any persistence-library upgrade receives dependency diff, license, migration, performance, and notarized-build review.

## Validation plan

1. Spike GRDB against the selected minimum OS and Swift toolchain; confirm static integration, license, signed/notarized build, and no domain leakage.
2. Simulate termination/power loss around every cursor, dirty-row, staging, and finalization boundary.
3. Generate the PRD 30-day benchmark databases at 500,000 and 1,000,000 entries; verify the <250 MB gate and measure write latency, query p95, checkpoint, and retention time.
4. Fill the volume during WAL growth, staging, migration backup, and finalization; verify read-only recovery.
5. Migrate golden database fixtures from every released schema and compare semantic checksums.
6. Corrupt WAL/main database fixtures and verify no silent rebuild or data disclosure.
7. Prove day-30 retention deletes path-level samples, findings, expired deleted nodes, and aged dirty paths while preserving only the active baseline and a path-free calibration/gap requirement.
8. Prove “Clear History” removes database/checkpoint/derived cache state without touching monitored files and reports deletion failure.
9. Confirm permissions are `0700` for the directory and `0600` for database/export-temporary files.

## Revisit triggers

- GRDB no longer supports the accepted OS/toolchain or introduces unacceptable supply-chain/licensing risk.
- Database size exceeds the 250 MB benchmark target after 30-day retention tuning.
- Query or write SLOs cannot be met with SQLite WAL on supported hardware.
- Product requires cross-device sync, multi-user access, or concurrent writers in separate processes.
- A validated threat model requires database encryption beyond FileVault/user permissions.
- External volumes or removable database placement become requirements.
