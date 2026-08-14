# SQLite Adapter Evidence Review

Status: **Completed for the phase-one adapter decision**

Reviewed: 2026-07-20

Chinese companion: [sqlite-adapter-evidence-review.zh-CN.md](sqlite-adapter-evidence-review.zh-CN.md). This English document is the evidence source of truth.

## Decision summary

GRDB 7.10.0 is technically and legally viable for SpaceTrace: its official package supports macOS 10.15+, Swift 6.1+/Xcode 16.3+, SPM integration, the system SQLite library, migrations, pooled WAL access, and backup APIs. Its permissive MIT dependency terms are compatible with SpaceTrace's PolyForm noncommercial source-available distribution when the GRDB copyright and license notice are preserved.

SpaceTrace will nevertheless retain the repository-isolated raw SQLite adapter for the remainder of phase one. Introducing GRDB while the durable journal, calibration publication, and recovery contracts are still changing would replace already-tested transaction code without yet providing a measured product benefit. GRDB remains the preferred candidate when history queries require concurrent read snapshots, provided a parity and performance spike passes first.

This conclusion completes the dependency/licence/local-build comparison. It does **not** accept ADR-004, prove a notarized distribution build, complete the 500,000/1,000,000-row benchmark, or qualify macOS 15.6 runtime behavior.

## Evidence matrix

| Question | GRDB 7.10.0 evidence | Raw SQLite evidence | Result |
| --- | --- | --- | --- |
| Platform/toolchain | The tagged manifest declares macOS 10.15+ and Swift tools 6.1; SpaceTrace targets macOS 15.6 and the host uses Swift 6.2.1/Xcode 26.1.1 | Links the OS `libsqlite3`; the current host CLI reports SQLite 3.51.0 | Both compatible on the build host |
| License | Tagged release is MIT; the notice must accompany substantial distributions | SQLite is supplied by macOS, so SpaceTrace does not vendor another database binary | GRDB acceptable with notice/SBOM work |
| Package surface | SPM exposes `GRDB` and `GRDB-dynamic`; upstream recommends `GRDB` when unsure | No package download or transitive Swift dependency | Raw has lower supply-chain surface |
| Concurrency | `DatabasePool` provides WAL-backed concurrent reads and serialized writes | Current actor owns one connection, so reads and writes are serialized | GRDB better matches the future history-query architecture |
| Migrations | `DatabaseMigrator` removes C-statement boilerplate, but SpaceTrace still owns migration ordering, checksums, backup, and recovery policy | Current forward migrations and rollback seams are explicit and repository-tested | GRDB reduces mechanics, not policy risk |
| Backup/recovery | GRDB wraps SQLite online backup | Raw adapter can call the same C API, but has not implemented migration backup yet | Neither option completes ADR recovery by itself |
| Domain isolation | Can remain private to `SpaceTracePersistence` | Already private to `SpaceTracePersistence` | Both satisfy the dependency rule |
| Current regression risk | Adoption requires translating more than journal CRUD: mount generations, bookmarks, staging/finalization, baselines, typed errors, and fault seams | Existing behavior already passes package and app gates | Retain raw adapter for phase one |

Primary upstream references:

- [GRDB 7.10.0 README and requirements](https://github.com/groue/GRDB.swift/blob/v7.10.0/README.md)
- [GRDB 7.10.0 package manifest](https://github.com/groue/GRDB.swift/blob/v7.10.0/Package.swift)
- [GRDB 7.10.0 MIT license](https://github.com/groue/GRDB.swift/blob/v7.10.0/LICENSE)
- [SQLite result-code definitions](https://www.sqlite.org/rescode.html)
- [SQLite WAL behavior](https://www.sqlite.org/wal.html)
- [SQLite integrity-check pragmas](https://www.sqlite.org/pragma.html#pragma_integrity_check)
- [SQLite online backup API](https://www.sqlite.org/backup.html)

## Reproducible local spike

The review resolved exact tag `7.10.0` in a disposable Swift package with deployment target macOS 15.6. The executable opened a `DatabasePool`, registered and ran one `DatabaseMigrator` migration, queried the resulting table, and exited successfully in Release configuration.

Recorded host evidence:

```text
Apple Swift 6.2.1
Xcode 26.1.1 (17B100)
GRDB 7.10.0 exact SPM resolution
Build of product 'GRDBSpike' complete
GRDB 7.10.0 static SPM spike passed
```

`otool -L` showed the system `/usr/lib/libsqlite3.dylib` and no separately embedded GRDB dynamic framework. This proves the tested default `GRDB` product linked into the executable and used system SQLite on this host. It is not an App Sandbox, code-signing, notarization, or oldest-OS runtime result.

## Reliability evidence added with this review

Schema v7 and deterministic tests now prove the following current-adapter properties:

- an actual `SQLITE_FULL` produced by `PRAGMA max_page_count` is mapped to a typed disk-full error and does not alter the previously committed bookmark;
- a valid SQLite fixture with a damaged database header is detected before persistent pragmas, returned as a typed corruption error, and is not silently replaced;
- an injected failure after schema v7 statements but before commit rolls back both schema objects and `user_version`, preserving the v6 semantic state;
- one fixed-clock retention transaction deletes expired deleted nodes, replaceable old baselines, and unreferenced completed scan runs while preserving current directory truth, unresolved dirty work, and the newest baseline for each scope;
- an injected failure after the first retention deletion rolls the entire retention transaction back;
- retention configuration rejects path-history windows outside ADR-004's 1–30 day bound.

The retention slice is intentionally limited to tables that exist today. Hourly/daily history samples, findings, aged dirty-path conversion to a path-free calibration requirement, database-size budgeting, idle WAL checkpointing, migration backup, read-only recovery UI, and “Clear History” are still future acceptance gates.

## Adoption gate for GRDB

Do not add GRDB to the production dependency graph until one focused change proves all of the following:

1. repository parity for every current transaction and typed failure;
2. migration from the latest released raw-SQLite schema without a file rewrite;
3. measured read/write, memory, binary-size, checkpoint, and retention results on the PRD fixtures;
4. exact-version lock, dependency diff, license notice, privacy manifest, and SBOM review;
5. signed App Sandbox build and Developer ID notarization when an identity is available;
6. macOS 15.6 and current-stable runtime qualification.

Until those gates pass, architecture diagrams should describe `SpaceTracePersistence` as a SQLite adapter and label GRDB as a candidate rather than an installed component.
