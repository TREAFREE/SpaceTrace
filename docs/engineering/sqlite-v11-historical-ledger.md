# SQLite v11 Historical Ledger

## Status

The schema-v11 persistence slice and production complete-scan integration are implemented and verified on the current development host. This closes the schema, migration, repository transaction, paired logical/allocated finalization, complete-parent disappearance reconciliation, qualified APFS stable-move evidence, production creation of projector work, bounded immediate/launch projection, retraction, retention, recovery-fixture, and current-host scale-benchmark work described here. The bounded Overview now consumes current-effective and immutable audit reads. This does **not** make SpaceTrace release-ready: minimum-OS qualification, manual accessibility/usability evidence, and distribution trust remain open.

ADR-004 and ADR-006 remain **Proposed**. Passing an implementation gate is evidence for review, not maintainer acceptance of an ADR.

## Authority and data model

V11 adds an immutable local ledger beside the existing current-state and v10 history tables:

- one store generation, opaque scope/subject/location dictionaries, and frozen attribution decisions;
- observation batches, frames, shared directory nodes, metric-specific logical/allocated endpoints, stable-identity evidence, and consecutive commit markers;
- pending projection work, immutable projections/findings/ranks/reason counts, projection checkpoints, and independent `evidence_invalidated` retractions;
- a persisted `off | days(1...30)` history policy, path-free gap state, committed baselines, terminal calibration receipts, and a separate path-free disabled receipt.

The database derives endpoint identity from store generation, committed node key, and metric. Provisional identifiers may be derived and compared inside the writer transaction, but they cannot escape the actor or be returned before `COMMIT`. A rollback exposes no committed endpoint or frame.

Every finding refers through native composite foreign keys to the exact baseline and comparison metric endpoints. The frame-commit trigger is the authority boundary: it rejects an incomplete logical/allocated pair, mismatched endpoint state, a non-unique or wrong-subject root, invalid parent membership, missing stable evidence, and late graph extension. Missing rows never become absence evidence.

## Transaction state machines

### Paired finalization

1. Validate the running scan, staged rows, supplied candidate, policy, stream, revision, and current dirty-work ownership.
2. If History Off is active, publish only current truth, suppress both v10 and v11 path history, remove historical baselines, and commit a path-free seven-day disabled receipt.
3. Otherwise, insert the batch, logical and allocated frames, shared nodes, metric endpoints, stable evidence, and both frame-commit markers in one writer transaction.
4. Rehydrate both frames inside the same transaction and compare them byte-for-byte with the Application candidate. Transaction-local IDs remain non-escaping until commit succeeds.
5. Publish current state, register deterministic projection work, consume matching dirty work, and commit one immutable terminal receipt.
6. A response lost after commit is recovered by the receipt and exact request digest. An identical retry returns the committed result; a changed immutable field fails with an immutable conflict.

The first committed pair for a metric is descriptive baseline state. Later consecutive pairs create projection work. Unsupported versions, stale work, cross-frame IDs, expired evidence, and non-authoritative Application results fail before a finding graph becomes durable.

### Projection and retraction

Pending work is selected deterministically by comparison sequence and work ID. The repository reloads authoritative frames, regenerates the version-1 result, checks exact equality with the supplied result, and commits projection, findings, ranking, reason counts, and checkpoint atomically. Failure before the checkpoint rolls the entire projection back and leaves work pending.

The public history repository has no retraction mutation. Only the Application integrity authorizer can create the non-`Codable`, non-public evidence-invalidation command; Persistence receives it through a package-scoped port and revalidates the stored finding and canonical draft digest. A retraction hides a finding from current-effective reads while audit reads preserve the original and retraction. V11 has no successor/replacement column and makes no supersession claim.

## Retention, History Off, and privacy

The hard evidence expiry is anchored to the earliest observation in the graph and is bounded to 30 days. A shorter persisted policy uses the earlier boundary. Retention is one ordered transaction: it removes retractions and dependent finding rows, projection/checkpoint/work state, terminal receipts and baselines, frame commits, stable evidence/endpoints, child-first nodes, frames/batches, orphan dictionaries, then unreferenced scan runs. Any injected failure or real `SQLITE_FULL` rolls back the policy change and every deletion.

History Off is distinct from Clear History. History Off persists across reopen, deletes path-bearing historical graphs and baselines, prevents new v10/v11 path-history writes, and preserves watched authorization, current state, monitoring, dirty operational truth, and permitted path-free capacity history. Reads expose typed `historyDisabled`, then `baselineUnavailable` after re-enabling until a fresh baseline commits. Clear History remains the separately confirmed full local reset described by ADR-004 and the privacy baseline.

Sensitive fields include raw paths, display names, scope/subject/location bytes, stable-object tokens and birth time, attribution decisions, observation times, bookmarks, dirty paths, and any digest derived from them. They may exist only in the protected local store for the bounded purpose. Release diagnostics, logs, test output, fixture manifests, and exports must not contain them. The cumulative privacy checker scans every committed file since the v11 plan boundary plus index, worktree, and untracked views; released SQLite fixtures are accepted only through deterministic generator, manifest, digest, integrity, and semantic verification.

## Migration, failure, and recovery

Migration 11 is forward-only and records the canonical complete-schema digest. It does not manufacture immutable evidence from v10 history. Before migration, the repository makes an atomic online backup; a failure preserves the source store and enters typed read-only recovery instead of rebuilding.

Released v10 and v11 golden databases are generated deterministically. V10 verifies upgrade to v11 without invented evidence. V11 is a canary containing committed endpoints, projection, finding, retraction, and embedded expiry metadata. Recovery validation checks schema digest, integrity, foreign keys, immutable shape, projection/finding references, expiry, and sensitive-artifact inventory.

An isolated main database copied without its WAL is always incomplete because a stale main file cannot prove whether committed WAL pages were lost. A complete online backup or a complete main/WAL bundle may qualify after validation. WAL checkpoint tests cover both successful truncation and a real busy reader; the latter remains typed/incomplete and never claims a clean backup.

## Current-host scale evidence

The final repository benchmark owns its SQLite connection and SQL inside `SpaceTracePersistence`; the executable receives metrics only. It uses the released v11 schema on a current application database, validates result cardinality on every query repetition, records query plans and full `dbstat`, and fails the command when a hard gate is exceeded.

The 30-day matrix first writes five expired days, then atomically retains 25 days. It covers no change, 100 scopes/high frame count, 100% stable identity, 2% daily movement, and a 50/50 v10-to-v11 overlap. Endpoint-write p95 is measured per at-most-500-node/two-metric chunk inside the frame transaction; finding-write p95 uses at-most-500-finding chunks. Query p95 uses 25 executions with exact row-count validation. Peak RSS is the process high-water mark and is therefore conservative across a matrix process.

Environment: Apple M5, 16 GB RAM, macOS 26.6.1 (25G76), Xcode 26.1.1 (17B100), internal storage. Power, thermal, and Low Power Mode were not captured, so elapsed insertion time is diagnostic. JSON SHA-256: `aa7935f83fb07262119108a78dc666a4fefd522e4989b4ee19795dd3e71a941d` (500k) and `871713e9768b75436222d337d9fa17409762bf46c38997f7890f072d649259e5` (1M).

| Samples | Worst checkpointed DB+WAL+SHM | Worst peak RSS | Endpoint write p95 | Finding write p95 | Pending work p95 | Effective Top 10 p95 | Legacy 7-day Top 100 p95 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 500,000 | 114,712,576 B | 86,933,504 B | 31.25 ms | 10.61 ms | 0.11 ms | 38.63 ms | 21.22 ms |
| 1,000,000 | 231,653,376 B | 114,032,640 B | 46.69 ms | 20.48 ms | 0.15 ms | 142.02 ms | 75.75 ms |

All ten scenarios reported `integrity_check=ok`, zero foreign-key violations, `secure_delete=ON`, and a zero-byte WAL after truncation. The 1M all-stable case was the largest at 231,653,376 bytes. The 1M overlap retained 500,000 v11 nodes and 500,000 v10 rows, used 214,601,728 bytes, and stayed at 114,032,640 bytes peak RSS. The growth query is root-bounded by binary range and deliberately uses `directory_history_growth`; wildcard-looking path text remains literal.

The current-host gates pass: complete database below 250,000,000 bytes, peak RSS below 150,000,000 bytes, 500-node/finding write p95 at or below 100 ms, and both v11 and legacy queries at or below 500 ms. These are current-host persistence gates, not macOS 15.6 or minimum-reference-hardware qualification.

## Exact non-claims and remaining release gates

This integrated slice still does not claim that:

- APFS directory link-set uniqueness and topmost complete-parent disappearance are now produced and verified through real Foundation and controlled disk-image tests; unsupported filesystems, moved/incomplete parents, occupied replacement locations, and every other unproved missing row remain suppressed;
- every legacy caller uses paired v11 finalization: the running authorized-volume and FSEvents calibration paths use it when persistent volume/mount context and the rich scanner/repository capabilities are available, while deliberately unsupported contexts stay on current-state publication without inventing history;
- replacement/supersession exists; v11 supports evidence invalidation only;
- automated Overview presentation of findings, uncertainty, retractions, History Off, and baseline-unavailable state is a substitute for manual assistive-technology or minimum-OS qualification;
- the reviewed 64-known/32-Unknown v2 classifier corpus is real-user accuracy evidence; it closes only the FR-007/KPI-03 open-repository regression gate;
- redacted user-controlled export, macOS 15.6 runtime, Apple-identity signing/notarization, clean quarantine install, upgrade/rollback, manual accessibility/usability, licenses/notices/SBOM, or public distribution is qualified.

Until those gates close and ADR-004/ADR-006 are accepted, the product release decision remains **NO-GO**. A locally generated ad-hoc DMG remains a controlled engineering artifact, not a public release.
