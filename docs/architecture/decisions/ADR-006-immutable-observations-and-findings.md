# ADR-006: Immutable observation endpoints and historical finding projection

## Status

Proposed — the pure contracts, schema-v11 persistence, production complete-scan paired finalization, and bounded projector lifecycle are implemented. Migration, transaction, retraction, retention, recovery-fixture, privacy, current-host 500k/1M benchmark, and production-path integration tests pass. The decision remains unaccepted until explicit-absence and stable-identity qualification, UI, minimum-OS, maintainer-adoption, and remaining release gates pass.

Date: 2026-08-11

Owners: SpaceTrace maintainers

Related requirements: FR-004, FR-005, FR-006, FR-007, FR-008, FR-012, FR-013, NFR-001, NFR-003, NFR-006

Implementation guide: [Immutable, Coverage-Aware Historical Findings](../../engineering/immutable-historical-findings.md)

Supersedes: none

Superseded by: none

## Context

SpaceTrace already exposes current directory aggregates and lossy hourly/daily history internally, and it has a pure deterministic path classifier. Those surfaces are not an audit-grade finding source. Schema v11 now persists validated versioned decisions and pure projection results. A complete production scan also captures directory-only measurements, direct-child coverage, birth-time-qualified object metadata, and frozen classification from the same traversal; when a persistent volume and mount generation are known, one transaction publishes current truth plus consecutive logical/allocated v11 frames and registers deterministic projection work. The projector drains new work after commit and resumes pending work at launch. The scanner still cannot emit explicit absent endpoints or prove directory link-set uniqueness, so missing rows remain missing evidence and production move findings remain suppressed. Overview presentation is not connected.

FSEvents reports lossy, coalesced invalidation hints. A rename flag contains neither a trusted source/destination pair nor a durable object identity. The scanner observes file identity to avoid allocated-byte double counting during one scan and records conservative directory object metadata for v11 candidates, but it deliberately records directory link status as `unknown`. Therefore name, inode alone, size, timestamp proximity, opposite deltas, or an FSEvents rename flag cannot establish a move.

The architecture currently says classifier schema participates in observation comparability. Classification does not change measured bytes, and rule upgrades must not sever otherwise compatible measurement history. Classification belongs after measurement comparison and must be frozen into each historical finding.

The existing ranked history query can return inclusive parent and child deltas. Avoiding a UI sum is insufficient: a ranked list can still present one physical change twice. The product needs a documented non-overlapping contribution policy before it can claim FR-006.

Finally, reconciliation may discover that the evidence supporting a finding is invalid. That is not the same operation as replacing the finding with a corrected explanation. A finding remains immutable; v11 may append a narrowly scoped evidence-invalidated retraction, while replacement requires a later correction model and schema.

## Decision drivers

- A finding must be traceable to immutable source endpoints and must survive classifier upgrades without silent reinterpretation.
- Unknown, partial, missing, revoked, unmounted, or discontinuous evidence must never become zero, deletion, or move.
- Move detection must favor precision over recall because a false move damages the product's core credibility.
- Parent and child aggregates must yield a non-overlapping ranked contribution with deterministic ordering.
- Wall-clock or timezone changes must not reorder commits.
- Invalidated evidence must disappear from the current-effective view without erasing the original audit record or pretending that a corrected replacement exists.
- The design must remain metadata-only, local, bounded, testable without SQLite, and compatible with the existing modular monolith.

## Options considered

### Option A — Generate findings from the current hourly/daily history read model

- Benefits: minimal schema and application changes.
- Costs: no immutable source endpoints, no explicit absence, no reliable move proof, and deleted paths may be absent from the read model.
- Risks: false deletion/move, silent historical rewrite, and parent/child double counting.
- Assessment: rejected.

### Option B — Infer moves from rename events, names, sizes, or adjacent opposite deltas

- Benefits: high apparent recall and little scanner work.
- Costs: FSEvents is lossy and does not pair paths; inode/name/size reuse and copies are common counterexamples.
- Risks: a copy can be called a move, two unrelated directories can be paired, and incomplete evidence can become a confident claim.
- Assessment: rejected.

### Option C — Immutable endpoints, explicit absence, pure comparison, frozen classification, and append-only findings/retractions

- Benefits: auditable causality, fail-closed gaps, deterministic move proof, classifier-version preservation, and idempotent crash recovery.
- Costs: schema-v11 tables, additional local metadata, a projection checkpoint, migrations, and more retention work.
- Risks: object identity APIs need cross-version qualification; conservative suppression reduces recall.
- Assessment: selected.

## Decision

### 1. Immutable observation endpoint

Every endpoint used by a finding has a durable endpoint ID and records:

- scope ID;
- persistent volume identity;
- mount generation;
- coverage epoch;
- subject identity and its basis (`stableFileSystemObject` or `normalizedPath`);
- normalized opaque location ID;
- metric;
- path-semantics and measurement-semantics versions;
- database-generated monotonic commit sequence;
- UTC wall time;
- one explicit state: `present(bytes, coverage)`, `absent(parentAbsenceReference)`, or `unknown(reason)`.

An absent endpoint is a stored fact, not a missing row. Its raw parent reference is not proof by itself. The Application frame validator must resolve that reference to a complete direct parent in the same compatible observation frame before promoting an absence transition. Permission loss, unmount, root replacement, event gaps without completed reconciliation, partial enumeration, and missing endpoint rows produce unknown/incomparable evidence.

### 2. Measurement compatibility

Two endpoints are measurement-compatible only when scope, persistent volume, mount generation, coverage epoch, subject, identity basis, metric, path semantics, and measurement semantics match, and the comparison commit sequence is strictly greater than the baseline sequence.

Wall-clock time may repeat or move backward; the monotonic commit sequence controls ordering. Classifier catalog/rule versions do **not** participate in byte-measurement compatibility. Classification happens only after a compatible `StorageChange` exists.

Expected evidence insufficiency returns a typed `incomparable` outcome. Reuse of one immutable endpoint ID on both sides returns a distinct `corrupt` outcome before compatibility checks, so it cannot be hidden as ordinary suppression. Corrupt identifiers, invalid state construction, invalid durable payloads, and checked-arithmetic failure remain errors.

### 3. Change and absence semantics

Complete present endpoints produce a metric-preserving signed inclusive delta. Raw absent-to-present and present-to-absent comparisons produce `appearanceCandidate` and `disappearanceCandidate`; only the validated Application frame projection can promote them to appearance and disappearance findings. Product copy must not claim the user created or deleted data at an exact event time; the times are observation endpoints.

A missing counterpart, partial value, unknown state, or invalid parent proof cannot produce a causal finding. The first complete baseline remains descriptive.

### 4. Move proof

The endpoint comparator may emit `relocationCandidate` after endpoint-level compatibility, complete presence, stable-identity basis, and a location change are established. That candidate is not a move claim. The Application frame projection produces a move only when all of the following hold:

1. both endpoints are present and complete;
2. both belong to the same persistent volume and mount generation;
3. both use the same unique stable filesystem-object identity;
4. source and destination location IDs differ;
5. all four logical parent corners (source/destination parent × baseline/comparison frame, allowing coincident parents) have complete compatible endpoint and direct-child coverage;
6. the identity is unique in both frames and is not hard-link/link-set ambiguous;
7. the platform identity includes an inode-reuse guard, such as an available generation token or birth time plus node kind.

Cross-volume changes are never moves. If stable identity or reuse protection is unavailable, SpaceTrace may report path appearance/disappearance or suppress the claim, but cannot pair the paths as a move. Content hashing is not introduced because it reads beyond required metadata and cannot distinguish copy from move.

The watched root has no parent inside its frame, so this projection cannot satisfy the parent-coverage proof for a root relocation. Root-path replacement, remount, and volume return are handled by the watched-scope and mount-generation lifecycle; they establish a new compatible baseline or an evidence gap, not a root move finding.

### 5. Parent/child contribution and ranking

For one compatible observation pair and metric:

```text
inclusiveDelta(node) = comparison(node) - baseline(node)

childFlowDelta(node)
  = sum(comparison immediate-directory-child bytes)
  - sum(baseline immediate-directory-child bytes)

exclusiveDelta(node) = inclusiveDelta(node) - childFlowDelta(node)
```

Only a `growth` draft or a top-level explicit `appearance` draft with a positive ranking contribution is eligible for the positive-growth ranking. Here, “top-level” means that the appearance is not already covered by an ancestor appearance in the same frame comparison. Growth uses a positive `exclusiveDelta`; a top-level appearance uses its positive inclusive delta exactly once while its unmatched descendants are collapsed under it. A confirmed move, zero or negative contribution, `decrease`, or `disappearance` is excluded from positive-growth Top 10 and may appear in a separate finding group. In particular, a decrease remains ineligible even if subtracting a larger negative child flow makes its computed `exclusiveDelta` positive.

If a branch lacks the complete immediate-child frame needed for exclusive calculation, it is ranking-incomparable. SpaceTrace does not subtract a partial child set. Confirmed ancestor moves consume implicit descendant moves that preserve the same parent relationship; independently reparented descendants remain separate moves.

The stable positive ranking key is:

1. ranking bytes descending;
2. comparison commit sequence descending;
3. scope ID by binary/UTF-8 ascending order;
4. reporting opaque location ID by binary/UTF-8 ascending order;
5. deterministic finding key ascending.

Localized display names, localized paths, category wording, SQLite row order, and wall-clock time are not final tie-breakers.

### 6. Frozen classification evidence

Measurement comparison completes before classification. Growth/appearance uses the comparison location; disappearance uses the baseline location; move retains both source and destination decisions and treats destination as the primary current explanation.

Every frozen decision contains the catalog version and one of:

- `classified`: category, confidence, rule ID, rule version, and path-free evidence code;
- `noMatchingRule`;
- `ambiguous`: stable ordered competing rule IDs.

Durable decisions and finding-projection payloads use explicit discriminated or structurally validated formats. Version-1 decoders fail closed on unknown fields, explicit-null/non-canonical optionals, contradictory state, invalid keys, inconsistent versions or sequences, duplicate/non-canonical ordering, and ranked keys that cannot be derived from the retained drafts. Until a schema-versioned compatibility policy is approved, decoders must not silently discard or normalize immutable evidence.

A rule/catalog upgrade does not rewrite or retract an earlier finding. Explicit correction or replacement, if later approved, creates a separately versioned projection and replacement record under a future schema.

### 7. Append-only projection and persistence obligations

Application code owns comparison, classification, hierarchy policy, finding projection, and authorization of typed integrity reconciliation. Persistence stores immutable endpoints, observation frames, pending projection work, findings, and independent retractions; it does not decide whether evidence means move or disappearance, and schema v11 stores no successor or replacement link.

A finding draft references its authoritative baseline and comparison observations by endpoint ID; copied path, display, timing, coverage, and classification fields are frozen explanation evidence, not a substitute for the immutable frame ledger. The v11 persistence transaction must enforce referential integrity from every finding to both endpoint rows and their owning frames, reject orphan or cross-frame references, and retain referenced evidence for at least as long as the finding that depends on it.

Schema v11 must:

- add append-only observation-frame and endpoint tables with parent/location/object evidence;
- persist explicit absence and path-free unknown/gap evidence;
- atomically register projection work when a complete scan finalizes;
- make projection idempotent after crash;
- persist finding algorithm/ranking versions, both endpoint IDs, change kind, inclusive delta, optional ranking contribution, and frozen classification decisions;
- persist only the version-1 independent `evidence_invalidated` retraction defined below, without a successor/replacement column;
- retain path-bearing endpoints/findings for at most 30 days under ADR-004, while preserving only approved path-free health/audit evidence afterward;
- migrate every released golden fixture and preserve the original database on failure.

No current v10 history row is retroactively presented as an immutable endpoint. The first v11 frame is a descriptive baseline.

### 8. Evidence-invalidated retraction and future replacement

An immutable finding is the original finding record together with its authoritative endpoints, frozen classifications, algorithm/ranking versions, canonical draft digest, and projection context. None of those fields is updated when later integrity work loses trust in the evidence. Ordinary retention may delete the complete expired graph, but it never edits the finding in place.

Schema v11 supports one independent, append-only retraction reason: `evidence_invalidated`. A retraction says only that the original finding is no longer current-effective because its evidence failed a typed integrity check. It does not assert a corrected category, amount, path, cause, or successor finding, and it does not satisfy the replacement/supersession requirement.

Only an explicitly typed reconciliation or integrity workflow may request a retraction. The request must identify the exact stored finding and include its exact stored canonical draft digest. A later missing path, rename hint, similar or matching size, classifier/catalog upgrade, or user cleanup action must never infer or request a retraction. An unknown target or stale draft digest fails closed.

That authorization is an enforceable API boundary, not caller convention. The public history repository exposes reads, frame finalization, and projection work, but no retraction mutation. An Application-internal integrity authorizer consumes a typed integrity failure together with the stored audit record and is the only code allowed to construct the non-`Codable` evidence-invalidation command; the command has no public or package initializer and copies the stored finding ID and draft digest rather than accepting them from UI input. Persistence accepts that capability only through a package-scoped reconciliation port and still revalidates the target and digest transactionally. UI, classifier, user-cleanup, and ordinary scan callers cannot construct or invoke this mutation surface.

Retraction idempotency is request-scoped. Repeating the same request ID with the same canonical request digest returns the already-committed retraction. Reusing that request ID with different fields is an immutable conflict, and a second request ID for an already retracted target is also a conflict. A retraction is committed atomically and is retained only as long as its target; retention deletes the retraction, finding, projection, endpoints, and dependent evidence as one ordered graph. It must not preserve a detached audit marker after the target expires.

The current-effective query excludes any finding that currently has a retraction, even when the query constrains findings through an earlier comparison sequence. The sequence bound is about observation/finding time, not an as-of correction view. A separate audit read continues to return the unchanged original finding together with its optional retraction record. Schema v11 therefore makes no claim to historical as-of correction semantics.

Primary finding UI must not present a retracted finding as current. Audit/detail UI keeps it visible and labels it as **Evidence invalidated**; it must not say that the finding was fixed, replaced, deleted, or cleaned up, and it must not imply any filesystem action. Exact wording, visibility, accessibility, and localization remain release-gated UI work.

A true correction or replacement requires a future approved model: frozen correction input, a generator/version registry, correction work and idempotent request ownership, a versioned correcting projection, an explicit successor relationship, retention/crash recovery semantics, benchmark evidence, and a schema migration plus ADR amendment. V11's retraction does not close the still-open replacement/supersession gate.

### 9. Privacy boundary

Raw paths, display names, opaque object tokens, normalized location keys, timelines, and classification decisions are Sensitive local data even when hashed. Object tokens and raw paths do not enter evidence codes, Release logs, telemetry, or default diagnostics. SpaceTrace remains metadata-only and reads no file content to establish identity.

## Consequences

### Positive

- Findings have auditable causal endpoints and deterministic semantics.
- Permission/mount/event gaps fail closed instead of fabricating deletion.
- Classifier changes no longer break measurement continuity or rewrite history.
- Exclusive contribution closes the parent/child Top 10 double-counting gap.
- Crash recovery can resume an idempotent projection from durable pending work.
- Current-effective reads can fail closed on invalidated evidence while audit reads preserve the immutable original and retraction.

### Negative and accepted trade-offs

- v11 needs more rows, indexes, migration fixtures, and retention work.
- Reliable directory identity may be unavailable on some filesystems; those cases suppress moves.
- Conservative explicit absence and ranking completeness reduce apparent recall.
- Existing v10 hourly/daily history cannot be upgraded into audit-grade endpoints.
- V11 retraction has current-validity semantics only; replacement and historical as-of correction remain unimplemented.

### Neutral or follow-up

- ADR-003 and ADR-004 remain Proposed and require their own acceptance gates.
- Explicit-absence capture, production APFS link-set/stable-identity qualification, Overview/menu-bar UI, corpus expansion, export, and macOS 15.6 qualification remain separate stages.
- A correction/replacement model, successor schema, and append-only supersession evidence remain a separate adoption gate; v11 retraction does not complete them.
- An observed disappearance describes evidence at a path; it never authorizes deletion and is not a reclaimability claim.
- Every category and finding is an explanation of observed metadata, never a deletion instruction, cleanup recommendation, or safety guarantee.

## Validation plan

Current-host schema-v11 persistence and production-path evidence is recorded in [SQLite v11 Historical Ledger](../../engineering/sqlite-v11-historical-ledger.md). It closes migration, immutable frame/finding commits, complete-scan paired publication, idempotent immediate/launch projection, evidence-invalidated retraction, ordered retention, released recovery fixtures, and the 500k/1M current-host persistence gates. It does not close explicit absence, stable move proof, minimum-OS, UI, classifier-corpus, export, distribution, or maintainer-acceptance gates.

1. Domain tests cover every compatibility mismatch, partial/unknown state, explicit absence, strict sequence ordering, wall-clock rollback, checked arithmetic, and Codable revalidation.
2. Application tests cover growth, decrease, appearance, disappearance, stable move, rename-only rejection, identity ambiguity, ancestor-move collapse, child reparenting, exclusive contribution, input-order permutations, and stable Top 10.
3. Filesystem tests cover directory identity availability, inode reuse guards, hard links, symlinks, clones, concurrent rename/delete, APFS image remount/replacement, and non-APFS suppression.
4. Persistence tests cover atomic frame/finding commits, crash-idempotent projection, exact-digest retraction idempotency/conflicts, current-effective and audit reads, the absence of a v11 successor surface, v6-v10 golden migration, disk full, corruption, migration rollback, WAL recovery, and target-coupled 30-day retention.
5. The 500,000/1,000,000-row benchmark must remain within the PRD database and query budgets after v11.
6. Release/privacy scans prove no path, display name, object token, or database dump enters logs or default diagnostics.
7. Real signed-sandbox flows cover restart, permission revocation, external-volume return, and controlled create/delete/rename on macOS 15.6 and the current stable macOS.

## Revisit triggers

- A supported filesystem cannot provide a stable object token with an acceptable inode-reuse guard.
- The endpoint ledger exceeds the 250 MB benchmark after 30-day retention and selected-node policy.
- Exclusive contribution cannot meet query latency or produces misleading results under a newly supported aggregate type.
- Product requirements add cross-volume move semantics, leaf-file history, or retention beyond 30 days.
- Apple introduces a public, privacy-preserving event API that provides durable source/destination object identity.
