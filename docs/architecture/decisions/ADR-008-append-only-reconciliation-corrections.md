# ADR-008: Append-only reconciliation revisions and correcting projections

## Status

Proposed

Date: 2026-08-13

Chinese companion translation: [ADR-008-append-only-reconciliation-corrections.zh-CN.md](ADR-008-append-only-reconciliation-corrections.zh-CN.md). This English document is the engineering source of truth.

Related requirements: FR-004, FR-005, FR-006, FR-007, FR-012, FR-013, NFR-001, NFR-003, NFR-006

Amends: [ADR-006](ADR-006-immutable-observations-and-findings.md) after acceptance

Corrected-finding identity and invalidation follow-up: [ADR-009](ADR-009-corrected-finding-identity-and-invalidation.md)

## Context

FSEvents tells SpaceTrace that an area may be stale; it does not provide byte deltas or a trusted event sequence. SpaceTrace therefore publishes current directory truth and audit-grade historical findings only after a complete calibration scan. The scan is bounded, dirty work is durable, and schema v11 preserves complete immutable observation frames and findings.

Two correction problems remain distinct:

1. The hourly and daily directory-history read model is provisional inside an open bucket. A later complete scan in the same bucket currently replaces the row selected by `(stream, path, bucket kind, bucket start)`. The visible value becomes more accurate, but the earlier revision and its scan relationship are not retained as an explicit audit chain.
2. A defect in an approved finding algorithm, ranking policy, or frozen classification input may require the exact same immutable frame pair to be projected again. Schema v11 can append `evidence_invalidated`, but it cannot name a corrected projection, represent an empty corrected result, or show which projection replaced the earlier explanation.

An arbitrary later scan cannot be used to rewrite an earlier time interval. It includes filesystem changes that happened after the original comparison and is not a time machine. Evidence discovered later may invalidate an earlier finding, but it can correct the earlier value only when the corrected input still describes the same observation interval. These temporal limits must be part of the data model rather than UI wording.

FR-004 also requires the product to expose the latest successful reconciliation and roots still pending, and to prove that a simulated event gap followed by a 5 GiB change is recovered by bounded reconciliation. Those are application-level obligations; a successor table alone does not satisfy them.

## Decision drivers

- Never update or silently reinterpret an immutable observation, finding, or committed projection.
- Preserve the earlier provisional history revision and its scan metadata when a later complete scan corrects the current bucket.
- Permit a corrected finding projection only from the exact original frame pair and a registered deterministic implementation.
- Never attach an unrelated later finding to an earlier interval merely because its path, size, name, or category looks similar.
- Keep current-effective reads simple and deterministic while retaining a complete audit chain.
- Make acknowledgement loss, retries, retention, migration, and corruption fail closed.
- Preserve the 30-day path-history boundary and the 250 MB one-million-node database gate.
- Keep raw paths, identifiers, correction inputs, digests, and timelines local and out of diagnostics.

## Options considered

### Option A — Update the earlier history or finding row in place

- Benefits: smallest query and schema change.
- Costs: destroys the evidence of what was previously shown and why.
- Risks: silent historical rewrite, retry ambiguity, and no independent audit.
- Assessment: rejected.

### Option B — Treat every correction as `evidence_invalidated`

- Benefits: schema v11 already supports it.
- Costs: can say only that evidence failed; cannot provide a corrected value or projection.
- Risks: an invalidation may be misrepresented as a correction and FR-004 remains incomplete.
- Assessment: retained only for evidence that cannot safely be reconstructed; rejected as the correction model.

### Option C — Link an arbitrary later finding as the successor

- Benefits: can reuse an existing later projection.
- Costs: the later comparison covers a different interval and may include unrelated changes.
- Risks: false temporal causality and misleading corrected byte counts.
- Assessment: rejected.

### Option D — Separate read-model revisions from same-evidence correcting projections

- Benefits: each correction has honest time semantics; provisional summaries and audit-grade findings retain different proof requirements.
- Costs: requires schema v12, a generator registry, two explicit correction workflows, migration, recovery, retention, and UI work.
- Risks: more rows and more complex current-effective queries.
- Assessment: selected.

## Decision

### 1. Two correction lanes

Schema v12 provides two independent append-only lanes:

- A **reconciliation revision** records each complete-scan revision of a provisional hourly or daily directory summary. It corrects the current read model without changing any earlier revision.
- A **correcting projection** reprojects the exact same immutable observation frames with an explicitly registered generator and frozen correction input. It may replace the current-effective projection while preserving the predecessor projection and every original finding.

Neither lane changes schema-v11 rows. Schema v11 continues to mean exactly what ADR-006 defines.

### 2. Append-only reconciliation revisions

Every complete calibration publication appends a revision for each affected directory/bucket key. A revision freezes:

- its database-owned positive revision ID;
- scope/stream identity, bucket kind, and bucket start;
- the directory subject/location reference and metric values;
- coverage and descendant count;
- the terminal scan-run ID, dirty-work revision, and observation time;
- an optional direct predecessor revision ID for the same exact bucket key;
- a canonical versioned payload digest.

The predecessor must be the current terminal revision for the same key. A first revision has no predecessor. A later revision in another bucket is ordinary history, not a correction edge. A revision is accepted only from a complete scan whose dirty-work revision still wins the atomic publication race.

The ordinary Overview query selects the terminal revision for each key. The audit query returns the complete predecessor chain. Original revisions are never updated. Schema v12 may retain the existing materialized table as a transactionally maintained cache during migration, but it is never the correction authority.

### 3. Registered same-evidence correcting projections

A correcting projection freezes:

- a 16-byte request ID and a canonical request digest;
- the predecessor projection ID and exact stored projection digest;
- the identical baseline and comparison frame IDs used by the predecessor;
- the registered finding-algorithm, ranking-policy, and correction-input format versions;
- the frozen correction input and its SHA-256 digest;
- the complete deterministic replacement generation result, including a valid empty result;
- a database-owned correction commit sequence and UTC commit time.

The replacement is a complete projection, not a patch to individual findings. Its baseline/comparison frame pair must be byte-for-byte identical to the predecessor pair. At least one registered semantic input version must change; replaying the same version and input is idempotence, not a correction.

The application contains a closed registry for every supported correction tuple. Persistence reloads both immutable frames, resolves the exact registry entry, regenerates the complete result, and requires value equality plus canonical digest equality before commit. Unknown versions, missing inputs, unsupported classifier migrations, partial frames, and result mismatches fail closed.

### 4. Successor graph and current-effective reads

Projection replacement is a linear append-only chain:

- one projection has at most one direct successor;
- one correcting projection has exactly one direct predecessor;
- a successor uses the same frame pair as its predecessor;
- cycles, branches, self-links, cross-scope links, and cross-metric links are rejected;
- the entire chain uses one retention anchor and one expiry boundary derived from the original observation pair.

The current-effective view resolves the terminal projection and returns only its findings and ranks, minus any independent evidence-invalidated retractions attached to that terminal projection. Schema v11 retractions cover original findings; ADR-009 adds the distinct schema-v13 target needed for corrected findings without rewriting frozen v12. The audit view returns every unchanged projection, finding, correction edge, frozen input digest, and retraction in chain order.

Schema v12 does not claim a historical “what the app believed before correction” query unless a caller explicitly requests the audit chain. A comparison-sequence limit is still an observation-time bound, not a correction-time snapshot.

### 5. Later evidence and temporal honesty

Later filesystem evidence may:

- append a new reconciliation revision for its own bucket;
- append an `evidence_invalidated` retraction when it proves an earlier finding's evidence is unusable;
- create ordinary findings for the later frame pair.

It may not become a correcting projection for an earlier pair unless the correction workflow has a complete, immutable input that still describes that exact earlier pair. Name, path, size, object-number reuse, later absence, or user assertion cannot manufacture that proof. When reconstruction is impossible, the honest result is invalidated/unknown, not a corrected byte value.

### 6. Authorization and idempotence

Public history repositories expose reads only. A correction command is non-`Codable`, package-scoped, and constructible only by an Application correction authorizer after it reloads the predecessor audit record, validates a registered correction input, and copies the stored IDs/digests. UI code cannot supply a finding/projection ID, digest, version, or successor directly.

The transaction has three outcomes: newly committed, already committed with byte-identical request/result, or immutable conflict. The request digest covers every version, predecessor identity/digest, frozen correction byte, and generated result. ACK-loss retry must return the prior commit without allocating another projection or edge.

### 7. Reconciliation status

Application status is derived from durable facts and exposes, per watched scope:

- the last successfully committed complete reconciliation time and commit sequence;
- whether dirty work is pending;
- the oldest pending-work observation/revision when available;
- a typed unavailable, permission-required, volume-unavailable, partial, failed, or history-disabled state.

Empty arrays and optional dates must not stand in for these states. Wall-clock time is presentation only; database sequences and dirty revisions determine order. The Overview and menu surface must never show a pending value as complete.

### 8. Retention, recovery, and privacy

All revisions and correction chains remain inside the configured 1–30 day path-history boundary. A chain is deleted atomically in dependency order at its shared expiry; retention cannot reveal a predecessor as current-effective between statements. History Off suppresses new path-bearing revisions/projections and removes them using the existing explicit policy while retaining operational current state. Clear History remains a separate full reset.

Migration uses an atomic pre-migration backup and released schema-v11/v12 fixtures. Recovery never invents a missing successor or rebuilds from unverified JSON. Main/WAL corruption follows the existing isolation and read-only recovery policy.

Raw paths, subject/location IDs, frame/projection IDs, correction input, request digests, and correction timestamps are Sensitive local data. They are excluded from logs and default diagnostic exports. Export may include only typed path-free correction counts/status unless a future ADR explicitly approves more.

## Consequences

### Positive

- A corrected provisional history value no longer erases the earlier revision that a user may have seen.
- Algorithm and classification corrections preserve exact frame/time semantics.
- A corrected projection can legitimately contain zero findings without pretending that one arbitrary finding replaced another.
- Current-effective and audit reads have separate, testable meanings.
- FR-004 can be verified end to end rather than inferred from a successor column.

### Negative and accepted trade-offs

- Schema v12 adds storage, query, migration, and retention complexity.
- Corrections that require unavailable historical evidence remain invalidations/unknown; recall is deliberately lower than credibility.
- The generator registry keeps old supported implementations available while retained correction work can reference them.
- A conservative path-history budget may delete the full audit chain earlier than a product with unbounded history.

### Guardrails

- No UPDATE surface exists for immutable revision, projection, finding, or correction rows.
- SQLite triggers and repository validation independently reject malformed graph edges and incompatible frame pairs.
- Queries reconstruct and validate canonical values before applying limits.
- Generator implementations are pure, deterministic, bounded, and registered in source with fixture vectors.
- UI copy uses “corrected after reconciliation” only for a committed revision/projection edge; otherwise it says pending, unavailable, or evidence invalidated.

## Validation plan

1. Observe every new contract test fail for the missing v12 model before implementation.
2. Freeze the exact schema, integer codes, digest format, indexes, and query plans only after a physical prototype stays below 250 MB for the released one-million-node workload, including correction rows and WAL/SHM.
3. Migrate deterministic v11 fixtures to v12; prove rollback, backup restoration, ACK-loss idempotence, immutable conflicts, corruption isolation, and unknown-version rejection.
4. Prove multiple same-bucket complete scans append a predecessor chain, select only the terminal revision for Overview, and preserve all audit revisions.
5. Prove same-frame registered reprojection can yield changed, empty, and re-ranked results while cross-frame, unregistered, branching, cyclic, and forged corrections fail closed.
6. Simulate an event gap, make a controlled 5 GiB allocated change, run bounded reconciliation, and meet KPI-02 in the correct watched subtree while the original audit metadata remains queryable.
7. Verify last-success/pending-root status across cancellation, partial coverage, supersession, sleep/wake, permission revocation, volume return, restart, History Off, and retention.
8. Run privacy, strict-concurrency, schema-fixture, 500k/1M benchmark, signed-sandbox, macOS 15.6, accessibility, DMG, and release-candidate gates before changing the release decision.

## Revisit triggers

- APFS snapshots or another platform API can reconstruct a trustworthy earlier filesystem state.
- A correction must span different observation frame pairs.
- The product needs correction-time as-of queries or branching expert opinions.
- Retention must preserve correction audit metadata longer than path-bearing evidence.
- Correction inputs need import, network synchronization, or user-authored evidence.
