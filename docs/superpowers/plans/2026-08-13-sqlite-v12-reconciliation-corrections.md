# SpaceTrace SQLite v12 Reconciliation Corrections Implementation Plan

> Execute one task at a time. Every implementation task follows RED → GREEN, focused verification, the common gate, a scoped Chinese commit, and push. Do not advance `PRAGMA user_version` until the physical schema and one-million-node gate pass.

**Goal:** Complete FR-004 without rewriting history: preserve each provisional hourly/daily summary revision, support registered same-frame correcting projections, expose durable reconciliation status, and prove a simulated event gap followed by a 5 GiB change is recovered by bounded calibration.

**Architecture:** Schema v12 adds two independent append-only lanes defined by ADR-008. `SpaceTraceApplication` owns correction invariants, registry lookup, authorizers, current-effective semantics, and typed status. `SpaceTracePersistence` assigns sequences, stores immutable rows, revalidates inputs, and owns atomic/idempotent transactions. Existing schema-v11 frames and findings remain byte-for-byte immutable. Later evidence from another interval may invalidate old evidence or create later findings, but may never pose as a same-interval correction.

**Tech stack:** Swift 6 tooling in Swift 5 language mode, Swift Testing, raw SQLite3 behind the existing repository actor, WAL, CryptoKit SHA-256, released-schema fixtures, deterministic physical benchmarks, SwiftUI/AppKit presentation, and the existing privacy/architecture/release gates.

## Global constraints

- Minimum deployment remains macOS 15.6 and Apple Silicon-first.
- No FSEvent flag, path/name/size match, clock proximity, or user assertion creates a byte correction.
- A reconciliation revision comes only from the same complete calibration traversal used for current publication and must win the dirty-revision compare-and-delete race.
- Revisions form a linear chain only within one exact `(scope, stream, subject/location, bucket kind, bucket start)` key. Crossing a bucket is ordinary history.
- A correcting projection uses the exact predecessor baseline/comparison frame IDs. Cross-frame “correction” is rejected even if output appears equal.
- A replacement is a complete projection and may contain zero findings. Individual finding rows are never patched.
- Schema-v11 observations, findings, ranks, reason counts, projections, and retractions receive no UPDATE path.
- The public repository exposes correction reads only. Mutation uses a package-scoped, non-`Codable` command whose IDs/digests are copied from an audit read by an Application authorizer.
- ACK-loss retry is exactly `newlyCommitted`, `alreadyCommitted` for a byte-identical request/result, or `immutableConflict`; it never allocates twice.
- Current-effective reads resolve one terminal projection. Audit reads preserve the complete chain. A comparison-sequence filter is not an as-of-correction filter.
- History Off suppresses and removes path-bearing revisions/corrections while keeping operational current state. Clear History remains a separate full reset.
- Revision and correction chains use one bounded 1–30 day expiry and are deleted atomically without temporarily resurfacing a predecessor.
- Raw paths, opaque IDs, frame/projection IDs, correction input, request digest, and timelines are Sensitive local data and never enter logs/default diagnostics.
- The complete post-maintenance database plus WAL/SHM must remain below 250,000,000 bytes for the released one-million-node workload; the pre-maintenance transient size must also be recorded.
- Every decoder and database row mapper is bounded, exact-shape, and fail-closed for unknown versions/codes, duplicate keys, overflow, and inconsistent graph edges.
- No release status wording changes until the full FR-004 integration fixture, migration/recovery/retention, status UI, current-host gates, and external qualification rows pass.

## Common gate

```bash
swift test --package-path Packages/SpaceTraceKit -Xswiftc -strict-concurrency=complete
./Scripts/check-architecture.sh
./Scripts/check-historical-ledger-privacy.sh
bash Scripts/verify-released-schema-fixtures.sh
git diff --check
git status --short
```

The final task additionally runs `make verify`, fresh RC packaging, DMG verification, quarantine checks, and the release-candidate qualification matrix.

## Task 1: Freeze the correction decision and executable plan

**Files:**

- Create `docs/architecture/decisions/ADR-008-append-only-reconciliation-corrections.md`
- Create `docs/architecture/decisions/ADR-008-append-only-reconciliation-corrections.zh-CN.md`
- Modify `docs/architecture/decisions/README.md`
- Modify `docs/architecture/technical-architecture.md`
- Create this plan

**Acceptance:**

- The ADR separates provisional read-model revision from same-evidence finding reprojection.
- It explicitly rejects arbitrary later-frame succession and in-place update.
- English and Chinese headings and normative meanings align.
- FR-004's last-success, pending-root, bounded-work, and 5 GiB fixture obligations are explicit.

**Verification:**

```bash
./Scripts/check-architecture.sh
rg -n "ADR-008|schema v12|same.*frame|5 GiB|pending" docs/architecture docs/product docs/superpowers/plans
git diff --check
```

Commit: `确立仅追加校准更正与 v12 计划`

## Task 2: Add pure revision, correction, and status contracts

**Files:**

- Create `Packages/SpaceTraceKit/Sources/SpaceTraceApplication/History/ReconciliationRevision.swift`
- Create `Packages/SpaceTraceKit/Sources/SpaceTraceApplication/History/HistoricalProjectionCorrection.swift`
- Create `Packages/SpaceTraceKit/Sources/SpaceTraceApplication/History/ReconciliationStatus.swift`
- Create matching tests in `Packages/SpaceTraceKit/Tests/SpaceTraceApplicationTests/`

**RED contract:**

- Positive IDs/sequences and bounded 16-byte request/32-byte digest types.
- Canonical exact bucket key and optional direct predecessor.
- First revision has no predecessor; successor requires exact key and strictly increasing database sequence.
- Correcting projection requires identical frame pair, predecessor digest, at least one changed registered semantic version/input, and no self/branch/cross-scope/cross-metric edge.
- A complete replacement result may be empty.
- Status is a closed enum: current, pending, partial, failed, permission-required, volume-unavailable, history-disabled, and baseline-unavailable.
- Wall-clock rollback does not reorder revision/correction/status evidence.
- Public durable values use custom Codable only where persistence/export genuinely requires it; invalid/unknown/explicit-null payloads fail closed.

**Verification:**

```bash
swift test --package-path Packages/SpaceTraceKit --filter 'ReconciliationRevisionTests|HistoricalProjectionCorrectionTests|ReconciliationStatusTests'
```

Commit: `建立校准修订与更正投影契约`

## Task 3: Prototype and freeze the v12 physical schema

**Files:**

- Create `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalCorrectionSchema.swift`
- Extend `Packages/SpaceTraceKit/Sources/SpaceTracePersistenceBenchmark/main.swift`
- Create `Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/SQLiteHistoricalCorrectionPhysicalDesignTests.swift`
- Update the v12 engineering benchmark evidence after the gate passes

**Provisional physical responsibilities:**

- Append-only reconciliation revision, predecessor edge, correction request/work, registered version/input, correcting projection edge, and status-support indexes.
- Native foreign keys for predecessor/successor/frame/projection ownership wherever SQLite can express them.
- Named triggers reject UPDATE, branch/cycle/self-link, incompatible pair/key, terminal-predecessor drift, and committed incomplete graphs.
- Exact integer codes, byte lengths, CHECK constraints, object/index manifest, schema digest, and EXPLAIN plans.
- Query order reconstructs canonical keys before LIMIT.

**RED/GREEN capacity gate:**

- Fix the workload distribution before measuring: scope count, frames/scope, one-million retained nodes, both metrics, dirty/correction ratio, revision-chain depth, empty/nonempty correcting projections, classifications, path/ID/payload byte distributions, legacy overlap, expired band, and WAL/checkpoint state.
- Record 500k and 1M no-correction plus correction-churn cases.
- If any final 1M main+WAL+SHM result is `>= 250,000,000`, redesign before Task 4.

**Verification:**

```bash
swift test --package-path Packages/SpaceTraceKit --filter SQLiteHistoricalCorrectionPhysicalDesignTests
swift run --package-path Packages/SpaceTraceKit SpaceTracePersistenceBenchmark --historical-corrections
```

Commit: `冻结 SQLite v12 更正账本物理设计`

## Task 4: Implement migration, codecs, and released fixtures

**Files:**

- Modify `SQLiteEventJournalRepository.swift` schema dispatch to v12
- Modify `SQLiteHistoricalFindingCodec.swift`
- Add `SQLiteHistoricalCorrectionRepository.swift`
- Add migration tests and released `v12/SpaceTrace.sqlite`
- Update the released-schema manifest and deterministic fixture generator/verifier

**RED contract:**

- Fresh database and v11→v12 produce the exact frozen object/schema digest.
- Existing v11 bytes and meanings are preserved; no historical successor is fabricated during migration.
- Existing directory-history rows become one honest initial revision or remain an explicitly documented legacy baseline; no fake predecessor chain is invented.
- Migration backup is atomic; injected failures before each boundary leave v11 intact and recoverable.
- Unknown codes/versions, invalid UTF-8/BLOB lengths, NUL, oversized payloads, and inconsistent graph rows fail closed.
- Released v12 fixture is deterministic, provenance-verified, privacy-safe, and migrates to itself without drift.

**Verification:**

```bash
swift test --package-path Packages/SpaceTraceKit --filter 'SQLiteHistoricalCorrectionMigrationTests|SQLiteHistoricalCorrectionCodecTests'
bash Scripts/verify-released-schema-fixtures.sh
```

Commit: `实现 v12 迁移与发布模式证据`

## Task 5: Make complete calibration append reconciliation revisions atomically

**Files:**

- Modify `HistoricalFindingPersistence.swift` and `EventJournalRepository.swift` ports
- Modify `SQLiteEventJournalRepository.swift` finalization primitive
- Extend `SQLiteHistoricalFindingRepository.swift` or the v12 repository adapter
- Add Application/Persistence transaction tests

**RED contract:**

- One complete scan publishes current state, terminal scan status, v11 frames/work, and v12 hourly/daily revisions in one transaction.
- A same-bucket later complete scan appends exactly one successor revision per key and leaves the predecessor unchanged/queryable.
- Superseded, partial, cancelled, failed, history-disabled, and already-expired scans append none.
- Dirty revision changes during scan prevent publication/correction and preserve pending work.
- ACK loss returns the prior revision IDs and does not allocate duplicates.
- No UPDATE is used as correction authority; an optional legacy materialized cache must be derivable from terminal revisions and validated transactionally.
- Wall-clock rollback may target an earlier display time but cannot reverse database revision order.

**Verification:**

```bash
swift test --package-path Packages/SpaceTraceKit --filter 'ReconciliationRevisionPublicationTests|SQLiteReconciliationRevisionTests|FileSystemCalibrationPipelineTests'
```

Commit: `接入完整扫描的仅追加校准修订`

## Task 6: Implement the registered correcting-projection workflow

**Files:**

- Create `HistoricalProjectionCorrectionRegistry.swift`
- Extend `HistoricalFindingProjector.swift`
- Implement the package-scoped SQLite correction port
- Add Application and Persistence correction tests

**RED contract:**

- Closed registry resolves an exact `(algorithm, ranking, correction-input-format)` tuple.
- Authorizer reloads the predecessor audit record and copies stored projection/frame IDs and digest; UI cannot construct the command.
- Persistence reloads the identical frame pair, reruns the registered implementation, compares full result and canonical digest, and commits projection+edge+checkpoint atomically.
- Corrected result may be changed, re-ranked, or empty.
- Same request/result is idempotent; changed request field is immutable conflict.
- Unknown version, same-version no-op masquerading as correction, cross-frame, branch, cycle, self-link, forged digest, unavailable frame, partial frame, and generator mismatch fail closed.
- Later evidence over a different frame pair may only use ordinary projection or evidence invalidation.

**Verification:**

```bash
swift test --package-path Packages/SpaceTraceKit --filter 'HistoricalProjectionCorrectionRegistryTests|HistoricalProjectionCorrectionServiceTests|SQLiteHistoricalProjectionCorrectionTests'
```

Commit: `实现注册式同证据更正投影`

## Task 7: Add current-effective/audit queries and durable status

**Files:**

- Extend historical overview/audit repository ports and SQLite queries
- Extend `StorageHistoryOverviewQuery.swift`
- Add status query/coordinator tests

**RED contract:**

- Overview selects only terminal reconciliation revisions and terminal correcting projections.
- Audit returns every predecessor, correction edge, original finding, digest, and independent retraction in canonical order.
- Limits apply after graph reconstruction/validation, never before.
- A retracted terminal finding remains hidden; replacing a projection never deletes/revives an unrelated retracted predecessor finding.
- Per-scope status exposes exact last successful sequence/time and pending state from durable dirty work.
- Restart, permission loss, unavailable volume, partial scan, failure, History Off, baseline unavailable, and fresh-baseline recovery remain typed.

**Verification:**

```bash
swift test --package-path Packages/SpaceTraceKit --filter 'HistoricalCorrectionQueryTests|ReconciliationStatusQueryTests|StorageHistoryOverviewQueryTests'
```

Commit: `接入更正结果查询与校准状态`

## Task 8: Prove recovery, retention, privacy, and scale

**Files:**

- Extend retention/recovery repositories and tests
- Extend privacy checker contract only for newly introduced source/fixture roles
- Update English/Chinese v12 engineering evidence

**RED contract:**

- Crash before/after each transaction boundary, commit ACK loss, main/WAL damage, migration failure, disk full, busy checkpoint, and restart have one typed outcome and no half-chain.
- Retention deletes correction edges and dependent rows atomically in verified FK order; no predecessor resurfaces.
- History Off suppresses new path-bearing evidence and removes all v12 revisions/corrections while keeping operational current state.
- Expired graph bytes leave app-controlled main/WAL/SHM after secure-delete maintenance; no forensic APFS claim.
- Diagnostic export contains only approved path-free correction counts/status.
- Final 500k/1M repository benchmark, retention churn, query latency, and database bytes pass the frozen budgets.

**Verification:**

```bash
swift test --package-path Packages/SpaceTraceKit --filter 'SQLiteHistoricalCorrectionRecoveryTests|SQLiteHistoricalCorrectionRetentionTests|HistoricalCorrectionPrivacyTests'
swift run --package-path Packages/SpaceTraceKit SpaceTracePersistenceBenchmark --historical-corrections
./Scripts/check-historical-ledger-privacy.sh
```

Commit: `完成 v12 更正账本恢复保留与容量门禁`

## Task 9: Complete FR-004 UI and the controlled 5 GiB fixture

**Files:**

- Modify Overview/menu-bar models and SwiftUI views
- Add presentation/accessibility tests
- Add opt-in controlled APFS reconciliation integration test and qualification script
- Update English/Chinese qualification docs

**RED contract:**

- Overview and menu show last complete reconciliation, pending roots/count, partial/unavailable state, and a truthful corrected badge/details.
- Keyboard, VoiceOver, Increase Contrast, Reduce Motion, and large text do not depend on color or hover.
- Simulated continuity loss creates durable root work without a fabricated cursor.
- A controlled sparse/allocated 5 GiB fixture under the authorized root is discovered after bounded calibration and attributed to the correct subtree at KPI-02 recall.
- Original revision/scan metadata remains in the audit query after the corrected terminal revision becomes current.
- Foreground responsiveness and configured entries/depth/duration/yield budgets remain enforced.

**Verification:**

```bash
swift test --package-path Packages/SpaceTraceKit --filter 'ReconciliationPresentationTests|ReconciliationKPIIntegrationTests'
SPACETRACE_RUN_APFS_RECONCILIATION_TESTS=1 swift test --package-path Packages/SpaceTraceKit --filter ReconciliationKPIIntegrationTests
```

Commit: `完成 FR-004 校准状态与 5GiB 资格验证`

## Task 10: Re-run release qualification and build the publishable DMG

**Files:**

- Update release checklist, implementation status, roadmap, changelog, and both language guides
- Modify release scripts only when a fresh failing contract proves a packaging gap
- Do not commit generated App/DMG artifacts

**Required gates:**

1. `make verify` from a clean tree.
2. macOS 15.6 runtime on real Apple Silicon hardware; later macOS runner evidence is additional, not a substitute.
3. Signed sandbox restart, permission revoke/reauthorize, same external volume return, different-UUID replacement, correction migration, and UI/accessibility matrix.
4. 24-hour soak plus Instruments energy evidence for the exact release commit.
5. Clean-account quarantined DMG install and replacement test.
6. Exact entitlement, Mach-O, minimum-OS, dependency, SBOM/notices, checksum, read-only DMG, and privacy audits.
7. Developer ID/notarization, or an explicit owner-approved ad-hoc distribution risk record with exact Gatekeeper installation instructions and no claim of publisher verification.
8. Owner-approved project license and ADR-002/003/004/006/008 adoption decision.
9. Fresh release decision record naming every passed/open row. A GitHub prerelease is allowed only when no P0 product/privacy/data-integrity gate remains open.

**Verification:**

```bash
make verify
./Scripts/package-release.sh --version <rc-version> --commit <release-commit> --output <empty-output-directory>
./Scripts/verify-release-artifacts.sh <release-output-directory>
./Scripts/qualify-release-candidate.sh <release-output-directory>/SpaceTrace-<rc-version>.app
```

Commit: `完成发布候选校准与 DMG 门禁`
