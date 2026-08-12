# SQLite v12 Correction Physical Prototype Evidence

Last updated: 2026-08-13

## Scope

This evidence freezes the physical layout selected for ADR-008. Production now
migrates fresh and v11 stores to `PRAGMA user_version` 12. The layout extends the released
v11 immutable observation ledger with compact reconciliation revisions,
registered correction input, linear correcting-projection work/checkpoints,
complete replacement findings/ranks/reasons, and current-effective query
indexes. Complete paired calibration now appends reconciliation revisions in
the same transaction as current truth, v11 frames, scan completion, the dirty
compare-and-delete, and the legacy materialized cache. It does not claim that
registered correcting-projection transactions, status/query UI integration,
macOS 15.6 qualification, signing, notarization, or release distribution is
complete.

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
`f235ace99c9352c1cb053f978781f97c2e53b582b8ce71cf7fabbd9f0640a706`.

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
| 500,000 | no correction | 500,000 | 480,000 | 0 / 0 | 149,007,600 B | 109,731,840 B | 0.799 ms | 0.053 ms |
| 500,000 | 2% correction churn | 500,000 | 480,000 | 47 / 18,424 | 170,616,640 B | 118,034,432 B | 0.860 ms | 0.044 ms |
| 500,000 | v10→v12 overlap | 250,000 | 240,000 | 0 / 0 | 132,191,920 B | 106,176,512 B | 0.671 ms | 0.030 ms |
| 1,000,000 | no correction | 1,000,000 | 960,000 | 0 / 0 | 299,248,080 B | 220,418,048 B | 0.703 ms | 0.029 ms |
| 1,000,000 | 2% correction churn | 1,000,000 | 960,000 | 47 / 36,848 | 341,543,528 B | 237,023,232 B | 0.756 ms | 0.050 ms |
| 1,000,000 | v10→v12 overlap | 500,000 | 480,000 | 0 / 0 | 264,027,400 B | 212,590,592 B | 0.691 ms | 0.024 ms |

All six scenarios reported `integrity_check=ok`, zero foreign-key violations,
`secure_delete=ON`, and zero WAL bytes after truncation. The largest final
case is 237,023,232 bytes, leaving 12,976,768 bytes under the
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
- Registered correcting-projection transactions and the remaining query/status
  integration gates are still incomplete; this stage alone does not complete
  FR-004.
