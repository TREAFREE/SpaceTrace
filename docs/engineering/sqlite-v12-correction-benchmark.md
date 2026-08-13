# SQLite v12/v13 Correction Physical Evidence

Last updated: 2026-08-13

## Scope

This evidence freezes the correction layout selected for ADR-008 and the
additive corrected-finding invalidation extension selected for ADR-009.
Production now migrates fresh, v11, and v12 stores to `PRAGMA user_version` 13.
The v12 layout extends the released
v11 immutable observation ledger with compact reconciliation revisions,
registered correction input, linear correcting-projection work/checkpoints,
complete replacement findings/ranks/reasons, and current-effective query
indexes. Schema v13 adds only the append-only corrected-finding retraction
target required to distinguish original and corrected finding identities.
Complete paired calibration now appends reconciliation revisions in
the same transaction as current truth, v11 frames, scan completion, the dirty
compare-and-delete, and the legacy materialized cache. It does not claim that
status/query UI integration, macOS 15.6 qualification, signing, notarization,
or release distribution is complete.

The registered same-frame correction transaction is now implemented behind a
closed source registry and a package-scoped Application authorizer. Both the
authorizer and SQLite reload the immutable predecessor and exact complete
frame pair; SQLite reruns the selected implementation, compares the complete
result and canonical digest, and atomically commits input, work, replacement
findings/ranks/reasons, and checkpoint. Request-ID retries after simulated
commit acknowledgement loss return the original correction, while changed
fields, partial/unavailable evidence, semantic no-ops, generator mismatch, and
checkpoint failure fail closed. The production registry deliberately contains
no correction tuple until a concrete correction algorithm and canonical input
fixture receive source review; arbitrary runtime registration is unavailable.

The prototype reuses immutable v11 observation nodes and their two metric
endpoints. One compact row represents the hourly and daily revisions for one
complete node observation; distinct public revision IDs are deterministically
derived from the database-owned node ID plus the bucket discriminator. A
correction-churn workload adds a real same-hour/same-day replacement scan for
2% of retained nodes and links each successor to its exact prior node. It also
adds complete same-frame correcting projections, including empty-result
support.

## Reproduction

```bash
swift test --package-path Packages/SpaceTraceKit \
  --filter SQLiteHistoricalCorrectionPhysicalDesignTests
swift run --package-path Packages/SpaceTraceKit \
  SpaceTracePersistenceBenchmark --historical-corrections
```

The benchmark runs one temporary SQLite database at a time and removes it when
the scenario ends. It writes
`SpaceTrace-v12-historical-corrections.json` under
`FileManager.default.temporaryDirectory`; the measured report SHA-256 was
`915140cafec33596e7ddc9153a0c6b319f6348fd3f88aca8f317ed87c08cbc01`.

## Fixed workload

- 500,000 and 1,000,000 requested retained directory samples.
- 25 retained days after seeding and deleting five expired days.
- Both logical and allocated v11 endpoints for every shared node.
- No-correction, 2% same-bucket reconciliation plus correcting-projection
  churn, and 50/50 v10-history/v11-node overlap.
- Stable-identity, attribution, path/ID byte distributions, frame commits,
  work/checkpoints, findings, WAL checkpoint, secure delete, integrity/FK,
  `dbstat`, and query-plan evidence inherited from the frozen v11 workload.
- Correction churn retained 47 complete correcting projections and 18,424 or
  36,848 replacement findings at 500k or 1M respectively.

## Current-host results

Host: MacBook Air, Apple M5, 16 GB RAM, macOS 26.6.1 (25G76), internal APFS
storage. These are current-host persistence results, not minimum-macOS or
minimum-reference-hardware qualification.

| Requested | Scenario | Retained v11 nodes | v12 revision rows | Correcting projections / findings | Pre-maintenance main+WAL+SHM | Final main+WAL+SHM | Revision P95 | Projection P95 |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 500,000 | no correction | 500,000 | 480,000 | 0 / 0 | 148,323,608 B | 109,744,128 B | 0.712 ms | 0.029 ms |
| 500,000 | 2% correction churn | 500,000 | 480,000 | 47 / 18,424 | 169,932,648 B | 118,046,720 B | 0.732 ms | 0.048 ms |
| 500,000 | v10→v13 overlap | 250,000 | 240,000 | 0 / 0 | 131,507,928 B | 106,188,800 B | 0.679 ms | 0.034 ms |
| 1,000,000 | no correction | 1,000,000 | 960,000 | 0 / 0 | 298,564,088 B | 220,430,336 B | 0.747 ms | 0.031 ms |
| 1,000,000 | 2% correction churn | 1,000,000 | 960,000 | 47 / 36,848 | 340,859,536 B | 237,035,520 B | 0.841 ms | 0.046 ms |
| 1,000,000 | v10→v13 overlap | 500,000 | 480,000 | 0 / 0 | 263,343,408 B | 212,602,880 B | 0.712 ms | 0.027 ms |

All six scenarios reported `integrity_check=ok`, zero foreign-key violations,
`secure_delete=ON`, and zero WAL bytes after truncation. The largest final
case is 237,035,520 bytes, leaving 12,964,480 bytes under the
250,000,000-byte post-maintenance gate. The pre-maintenance values are recorded
truthfully and are not constrained by that long-lived storage gate.

## Frozen boundaries

- The v12 object manifest contains eight tables, seven indexes, and fifteen
  named validation/immutability triggers. Its correction-object digest is
  `e3fcbb2d62f319f3dde2e1deb184a30c0acd5a13691a2ae8e0d903eef1796b25`.
- Revision insertion requires a complete committed node, exact same-key
  terminal predecessors for the hourly and daily chains, durable 32-byte
  payload digest, and a bounded derived identity.
- Correcting projections require one committed v11 root projection, one frozen
  registered correction input, exact predecessor digest, linear chain
  ownership, shared frame/expiry authority, and an atomic checkpoint whose
  finding ordinals, rank ordinals, and reason cardinality are complete.
- Unknown codes, cross-frame findings, stale digests, branches, self-links,
  incomplete checkpoint graphs, and post-checkpoint child writes fail closed.
- Production migration uses an atomic pre-migration backup, preserves every
  v11 value, invents no revision/correction edge, and validates the complete
  schema digest
  `04fba44ae486b4d2f54324bd2068838675162103846d58abfd89fbdebcd059cf`
  before serving writes.
- The additive v12→v13 migration preserves every v12 row, creates no synthetic
  retraction, and validates the full schema digest
  `cd10e239cc6067a77c4e51a0d862ad6942c406b24a2ca2962304bd77ffbc49a4`
  before serving. The released v13 fixture, generator, semantic digest, and
  schema-object digest are independently verified by the fixture gate.
- Legacy `directory_history_sample` rows remain an explicitly lossy legacy
  baseline; migration never re-labels them as immutable v12 revisions.
- The deterministic released v12 fixture contains two complete paired
  observations, four revisions, one committed original projection, and one
  checkpointed empty correcting projection. Its generator, bytes, semantics,
  and schema-object digest are independently revalidated byte-for-byte.
- Complete calibration publishes only present, completely measured directory
  revisions. Same-bucket successors retain their predecessor, database-derived
  order remains authoritative across wall-clock rollback, and ACK-loss retry
  returns the prior revision identities without allocating duplicates.
- Dirty-revision loss, superseded/partial/cancelled/failed/history-disabled or
  already-expired scans append no revision. Retention removes an entire
  same-bucket chain and any dependent correcting-projection graph atomically
  before deleting v11 nodes.
- Registered correcting-projection transactions, versioned current-effective
  and audit queries, durable reconciliation status, recovery/retention,
  corrected-finding invalidation, diagnostics, and Overview presentation are
  implemented and covered by strict-concurrency Application/SQLite/App tests.
  A current-host APFS qualification allocated and flushed a real 5 GiB file,
  introduced a kernel-drop continuity gap, and recovered the exact target
  subtree with an allocated growth finding of at least 5 GiB. The release KPI
  still requires the documented repeated prototype matrix; macOS 15.6,
  accessibility, signed distribution, and notarization remain separate gates.
