# First Implementation Slice Status

Status: **Architecture spike; not user-visible production behavior**

Last verified: 2026-07-18

This document records what the first implementation slice proves and, equally importantly, what it does not prove. ADR-003 and ADR-004 remain **Proposed** until their complete validation plans and maintainer review are satisfied.

## Implemented evidence

| Area | Evidence now in the repository | Proven invariant |
| --- | --- | --- |
| Domain observations | Checked byte quantities, typed identities, coverage states, comparable observations, and metric-preserving deltas | Unknown or partial evidence cannot be presented as a complete zero-byte observation |
| FSEvents bridge | Public flag interpretation, restart-safe full-history replay, root-change sentinel handling, and a single-consumer bounded `AsyncThrowingStream` adapter | Events are invalidation hints only; callback-buffer loss becomes an explicit calibration gap and sentinel ID zero never becomes a durable cursor |
| Invalidation mapping | Adapter-to-application semantic mapping, lexical scope validation, file-to-parent projection, replay-overlap filtering, and ancestor coalescing | Ambiguous paths and continuity gaps sacrifice precision by falling back to scope calibration; they never manufacture narrow certainty |
| Metadata calibration scanner | Foundation/Darwin metadata-only traversal with explicit entry, depth, duration, batching, and cooperative-cancellation budgets; same-volume enforcement; no symlink traversal; hard-link allocation deduplication; typed coverage gaps | File contents are never opened; leaf paths do not cross the directory-aggregate boundary; budget exhaustion, permission loss, mount boundaries, and cancellation cannot become complete evidence |
| Calibration pipeline | Actor-isolated ingestion and bounded reconciliation orchestration behind an application-owned scanner port, with structured asynchronous staging | Partial and cancelled scans discard staging and retain dirty work; a completed stale scan cannot publish data or clear work updated while it was running |
| Event journal port | Application-owned stream, cursor, dirty-region, row-revision, reason, batch, and conditional-resolution contracts | A checkpoint cannot be accepted without durable dirty work in the same batch; cursor-free sentinels cannot move it |
| SQLite prototype | Actor-owned SQLite3 connection, WAL, schema v3, big-endian `UInt64` cursors and revisions, scan-run and directory-stage tables, current directory aggregates, atomic publication, cursor-free calibration markers, and rollback fault seam | Durable cursor advancement is atomic with dirty-region persistence and cannot regress; only complete, revision-current scans publish and mark missing descendants deleted |
| Build integration | Local `SpaceTraceKit` package linked to the macOS application target | The application composition root can depend on modular non-UI targets without source duplication |

## Verification evidence

The following gates passed on 2026-07-18 with Swift 6.2.1 and Xcode 26.1.1:

- `swift test --package-path Packages/SpaceTraceKit`: 78 tests in 13 suites;
- the same package tests with complete strict-concurrency diagnostics and compiler warnings treated as errors;
- an adapter-to-application-to-real-SQLite integration test with an injected calibration scanner;
- deterministic metadata fixtures for permission loss, symlinks, mount boundaries, hard links, budgets, and cancellation, plus a production-adapter test scoped to a disposable temporary directory;
- `make verify`, including architecture checks, package tests, Xcode scheme discovery, Debug build, application unit tests, and Release build;
- Xcode compile and link target `arm64-apple-macos15.6` with the local package resolved from this repository.

The strict-concurrency run is an audit for newly introduced package code. The application target remains in Swift 5 language mode as recorded by ADR-001; a repository-wide Swift 6 migration is still a separate decision and validation task.

## Deliberately not claimed

- No user-facing scan, history, explanation, menu-bar, permission, or export workflow is implemented.
- The production scanner and schema-v3 staging path are not wired into the application composition root or any user-visible workflow yet.
- Scan scheduling does not yet react to thermal state, battery state, or system load. Hard-link deduplication is bounded by the entry budget but remains in memory for each scan run.
- Permission scope acquisition, security-scoped bookmark lifecycle, cloud placeholder classification, and APFS snapshot reconciliation are not implemented.
- No exact byte delta or process attribution is inferred from FSEvents.
- The native FSEvents bridge has not yet passed an isolated APFS-volume lifecycle/integration suite.
- The SQLite adapter is a dependency-free architecture prototype. ADR-004's GRDB, migration-fixture, retention, disk-full, corruption, and benchmark decisions are still open.
- macOS 15.6 runtime qualification is not complete; compiling for the deployment target on a newer host is not runtime evidence.
- Full Disk Access, App Sandbox removal, Developer ID signing, notarization, distribution, and update behavior are unchanged and remain governed by their proposed decisions.

## Next acceptance gates

1. Run FSEvents create/start/replay/cancel/drop integration tests on a disposable APFS scope without scanning a developer home directory.
2. Decide per-device stream identity and volume-generation behavior before persisting production cursors.
3. Complete the ADR-004 GRDB-versus-raw-SQLite review, including license, build, migration, and notarization evidence.
4. Expand the schema migration fixture matrix and add disk-full/corruption tests, retention behavior, and oldest-supported-OS qualification.
5. Add permission-scope acquisition and production scan scheduling, then wire the accepted scanner and repository adapters into the composition root.
6. Keep all spike code unreachable from user-visible workflows until its corresponding ADR is accepted.
