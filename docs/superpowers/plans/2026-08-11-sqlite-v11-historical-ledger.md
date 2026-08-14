# SpaceTrace SQLite v11 Historical Ledger Implementation Plan

> **For agentic workers:** execute one task at a time with TDD. A task is not complete until its focused tests, the common slice gate, independent review, Chinese commit, and push all succeed.

**Goal:** Prove and persist authoritative immutable observation frames, deterministic v1 finding projections, auditable no-replacement retractions, and bounded 30-day deletion in SQLite schema v11 without reinterpreting schema-v10 history as causal evidence.

**Architecture:** `SpaceTraceApplication` owns an endpoint-ID-free paired observation candidate and the persistence port. SQLite assigns one shared node row, two metric endpoints, and the monotonic logical/allocated sequences inside a single transaction; committed endpoint IDs are derived afterward from an immutable store generation, the DB-owned node ID, and metric. The physical schema normalizes repeated scope, subject, location, path, and classification data so the released 30-day 500k/1M workload can stay below the 250 MB product gate without weakening native endpoint foreign keys. A work row without a checkpoint is the only pending-projection state. Projection and retraction commits are append-only and idempotent.

**Honest boundary:** this slice proves the Application contract and SQLite adapter. The production scanner does not yet collect the stable directory identity, complete-parent absence evidence, or frozen classification required to build the candidate pair, so `FileSystemCalibrationPipeline` continues to use the legacy finalization entry point during this slice. Production integration, replacement/supersession, UI, corpus/export, and signed macOS 15.6 qualification remain release blockers and must not be claimed complete here.

**Tech stack:** Swift 6 package tooling in Swift 5 language mode, Swift Testing, raw SQLite3 behind the existing repository actor, WAL, deferred foreign keys, strict version-1 codecs, and CryptoKit SHA-256 over canonical length-prefixed requests/results.

## Global constraints

- The minimum deployment target remains macOS 15.6.
- Schema-v10 hourly/daily rows are never backfilled as immutable v11 endpoints. The first v11 frame for each `(scope, metric)` is only a descriptive baseline.
- SQLite, never a caller or wall-clock timestamp, creates each positive `ObservationCommitSequence` using `INTEGER PRIMARY KEY AUTOINCREMENT`; retention must not permit reuse of a deleted maximum.
- Only v11 filesystem identity/path columns are constrained here: they are strict UTF-8 bytes stored as BLOB, bound with an explicit byte count, bounded by the next bullet, and compared without `NOCASE`, `LIKE`, `CAST AS TEXT`, normalization, or `sqlite3_bind_text(..., -1, ...)`.
- V11 uses tighter reviewed budgets rather than relying on the SQL maximum alone: IDs/tokens/paths are at most 4 KiB, display names and rule/evidence codes at most 1 KiB, frozen canonical payloads at most 64 KiB, one frame at most 50,000 nodes and 16 MiB of decoded UTF-8/evidence bytes, and only one two-frame projection may be materialized at a time. Exceeding any budget is a typed evidence gap, never truncation or partial persistence.
- Raw paths, display names, scope/subject/location IDs, object reuse guards, generation tokens, frozen payloads, and hashes remain Sensitive local data. They never enter logs, diagnostics, error text, fixture names, or public issue artifacts.
- A frame pair becomes authoritative only when its normalized dictionaries, shared batch/nodes, two metric endpoint sets, stable/classification evidence, DB-owned commit markers, and either baseline markers or projection work commit together.
- `HistoricalPairedObservationCandidate` contains shared non-metric context/topology and exactly one logical plus allocated value for every node. It contains no endpoint ID, sequence, database key, `Codable`, or serialization surface. The transaction assigns shared node IDs and two deterministic consecutive sequences or commits none of them.
- The new paired finalization path has explicit `.published(.newlyCommitted/.alreadyCommitted)`, `.superseded`, and `.historyDisabled` outcomes. ACK-loss retries inspect terminal scan state and immutable receipts before requiring `running` state.
- The existing production finalization and the new paired adapter entry both delegate to one private SQLite transaction primitive. The legacy entry writes no v11 frame and remains a documented release blocker until scanner integration removes it. Both entries read the same persisted history policy; History Off must still publish current state while suppressing both legacy `directory_history_sample` writes and new v11 path-bearing evidence. It is not Clear History: the latter remains a separate full database/checkpoint/cache reset under the privacy baseline and is not implemented by Task 7.
- Endpoint and finding evidence is insert-only. Public APIs expose no update. Named `BEFORE UPDATE` triggers reject mutation; retention may delete an explicitly computed expired graph in dependency order.
- Pending projection means `historical_projection_work` exists and no checkpoint with that `work_id` exists. Baseline markers are a separate table; there is no synthetic `expired` checkpoint state.
- The projection commit reloads both frames, reruns the exact version-1 `HistoricalFindingGenerator`, and requires value equality plus canonical digest equality before writing normalized finding rows.
- Schema v11 accepts only algorithm/ranking policy version 1. It implements independent `evidence_invalidated` retraction. Replacement, algorithm correction, classification correction, same-pair reprojection, and historical as-of correction views require a future approved schema/model and remain release blockers.
- Active-ledger path-bearing v11 evidence expires from the earliest node observation in its paired batch, never from a later commit: `retention_anchor_ms = MIN(node.observed_at_ms)` and `expires_at_ms = retention_anchor_ms + 2_592_000_000`. Deletion compares expiry directly with `referenceDate`; a shorter policy or history-off mode may expire it earlier, and an already-expired candidate is never newly committed.
- A retention run is not complete until application-artifact logical scrub (`secure_delete=ON` plus a non-busy WAL truncate checkpoint) has removed expired bytes from the app-controlled SQLite artifact set. This is not a forensic-deletion claim for APFS snapshots, Time Machine, SSD wear leveling, or user-created copies.
- Every task follows RED → GREEN. After focused tests, every task runs the common slice gate below, receives independent code/database or requirements review, stages only its named files, creates the listed Chinese commit, and pushes the active branch.

### Common slice gate

```bash
swift test --package-path Packages/SpaceTraceKit -Xswiftc -strict-concurrency=complete
./Scripts/check-architecture.sh
./Scripts/check-historical-ledger-privacy.sh
git diff --check
git status --short
```

The final task additionally runs `make verify`. Never use an all-files staging shortcut in a dirty worktree.

## File structure

- Create `Packages/SpaceTraceKit/Sources/SpaceTraceApplication/History/HistoricalFindingPersistence.swift`: candidates, paired finalization request/outcome, work/query/retraction values, and the persistence port.
- Create `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalFindingSchema.swift`: provisional physical schema, frozen v11 DDL, exact object manifest, integer wire codes, canonical schema digest, and a narrow `@_spi(Benchmark)` prototype entry used by the separate benchmark target.
- Create `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalFindingCodec.swift`: bounded UTF-8 BLOB binding/decoding and canonical request/result digests.
- Create `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalFindingRepository.swift`: an internal handle-bound statement store and pure row mappers. It never begins/commits a transaction and never owns or exposes the actor's connection.
- Modify `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteEventJournalRepository.swift`: schema dispatch and the single internal calibration-finalization transaction primitive.
- Modify `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteRetentionPolicy.swift`: effective v11 expiry, typed counts, and scrub status.
- Extend `SpaceTracePersistenceBenchmark` with the exact v11 physical prototype and final repository workload before migration v11 is frozen.
- Add deterministic released v10 and v11 fixtures and manifest-v2 semantic/schema digests.
- Add matching English/Chinese v11 engineering evidence only after implementation and benchmark gates pass.

## Provisional v11 relational contract

This contract is deliberately **provisional** until Task 2 proves the complete table/index set below at 500,000 and 1,000,000 retained directory samples, where every sample includes logical and allocated evidence. If the 1M complete-database main+WAL+SHM result is not below 250,000,000 bytes, the schema must be redesigned before `PRAGMA user_version` is raised to 11.

All integer discriminants are frozen in `SQLiteHistoricalFindingSchema`; unknown codes fail closed:

- metric: `1=logical, 2=allocated`;
- identity basis: `1=stable object, 2=normalized path`;
- endpoint state: `1=present, 2=absent, 3=unknown`;
- coverage: `1=complete, 2=partial, 3=unknown` (present measurement coverage accepts only 1/2);
- unavailability: `1=permission denied, 2=volume unavailable, 3=continuity gap, 4=incomplete enumeration, 5=identity unavailable, 6=endpoint missing`;
- attribution decision: `1=classified, 2=no matching rule, 3=ambiguous`;
- attribution category: `1=developer tools, 2=virtualization, 3=AI models/caches, 4=creative caches/render data, 5=games, 6=logs/caches, 7=cloud local data, 8=snapshot factors`;
- confidence: `1=high, 2=medium, 3=low`;
- stable guard: `1=generation token, 2=birth time`; node kind `1=directory`; link status `1=unique, 2=ambiguous, 3=unknown`;
- baseline checkpoint: `1=first observation, 2=retention rebased`;
- calibration receipt outcome: main receipt `1=published, 2=superseded`; the separate path-free disabled-receipt table is application outcome `3=history disabled`;
- finding kind: `1=growth, 2=decrease, 3=appearance, 4=disappearance, 5=move`;
- reason category: `1=finding suppression, 2=ranking exclusion, 3=collapse`;
- finding reason codes 1...38 follow this explicit frozen order: frame root/scope/volume/mount/coverage-epoch/metric/path-semantics/measurement-semantics/non-increasing; missing baseline/comparison; endpoint scope/volume/mount/coverage-epoch/subject/identity-basis/metric/path-semantics/measurement-semantics/non-increasing/incomplete-coverage/unavailable/location-changed-without-stable-identity/location-changed-without-two-present-endpoints; stable evidence missing/reuse-guard-mismatch/node-kind-mismatch/link-set-not-unique; move-parent-evidence-incomplete; ranking incomplete-direct-children/incomplete-child-measurement/kind-ineligible/non-positive; collapsed implicit-descendant-move/inherited-move-facet; covered-by-ancestor appearance/disappearance;
- retraction: `1=evidence invalidated`;
- path-free gap: `1=aged pending projection, 2=expired evidence, 3=projection corruption`.

```sql
CREATE TABLE historical_store_identity (
    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
    format_version INTEGER NOT NULL CHECK(format_version = 1),
    store_generation BLOB NOT NULL
        CHECK(typeof(store_generation) = 'blob'
            AND length(store_generation) = 16
            AND store_generation != zeroblob(16))
) WITHOUT ROWID;

CREATE TABLE historical_scope (
    scope_key INTEGER PRIMARY KEY,
    scope_id BLOB NOT NULL UNIQUE
        CHECK(typeof(scope_id) = 'blob' AND length(scope_id) BETWEEN 1 AND 4096)
);

CREATE TABLE historical_retention_policy (
    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
    path_history_days INTEGER NOT NULL
        CHECK(path_history_days BETWEEN 0 AND 30),
    updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
) WITHOUT ROWID;

INSERT INTO historical_retention_policy(
    singleton, path_history_days, updated_at_ms
) VALUES (1, 30, 0);

CREATE TABLE historical_subject (
    subject_key INTEGER PRIMARY KEY,
    scope_key INTEGER NOT NULL
        REFERENCES historical_scope(scope_key) ON DELETE RESTRICT,
    identity_basis INTEGER NOT NULL CHECK(identity_basis IN (1, 2)),
    subject_id BLOB NOT NULL
        CHECK(typeof(subject_id) = 'blob' AND length(subject_id) BETWEEN 1 AND 4096),
    UNIQUE(scope_key, identity_basis, subject_id)
);

CREATE TABLE historical_location (
    location_key INTEGER PRIMARY KEY,
    scope_key INTEGER NOT NULL
        REFERENCES historical_scope(scope_key) ON DELETE RESTRICT,
    path_semantics_version INTEGER NOT NULL CHECK(path_semantics_version > 0),
    location_id BLOB NOT NULL
        CHECK(typeof(location_id) = 'blob' AND length(location_id) BETWEEN 1 AND 4096),
    path_utf8 BLOB NOT NULL CHECK(typeof(path_utf8) = 'blob'
        AND length(path_utf8) BETWEEN 1 AND 4096
        AND substr(path_utf8, 1, 1) = X'2F' AND instr(path_utf8, X'00') = 0),
    display_name_utf8 BLOB NOT NULL
        CHECK(typeof(display_name_utf8) = 'blob'
            AND length(display_name_utf8) BETWEEN 1 AND 1024
            AND instr(display_name_utf8, X'00') = 0
            AND instr(display_name_utf8, X'2F') = 0),
    UNIQUE(scope_key, path_semantics_version, location_id)
);

CREATE TABLE frozen_attribution_decision (
    decision_id INTEGER PRIMARY KEY,
    format_version INTEGER NOT NULL CHECK(format_version = 1),
    canonical_payload BLOB NOT NULL CHECK(typeof(canonical_payload) = 'blob'
        AND length(canonical_payload) BETWEEN 1 AND 65536),
    canonical_sha256 BLOB NOT NULL UNIQUE
        CHECK(typeof(canonical_sha256) = 'blob' AND length(canonical_sha256) = 32),
    catalog_version INTEGER NOT NULL CHECK(catalog_version > 0),
    decision_kind INTEGER NOT NULL CHECK(decision_kind IN (1, 2, 3)),
    category_code INTEGER
        CHECK(category_code IS NULL OR category_code BETWEEN 1 AND 8),
    confidence_code INTEGER
        CHECK(confidence_code IS NULL OR confidence_code BETWEEN 1 AND 3),
    rule_id BLOB,
    rule_version INTEGER,
    evidence_code BLOB,
    CHECK(
        (decision_kind = 1
            AND category_code IS NOT NULL AND confidence_code IS NOT NULL
            AND typeof(rule_id) = 'blob' AND length(rule_id) BETWEEN 1 AND 1024
            AND rule_version > 0 AND typeof(evidence_code) = 'blob'
            AND length(evidence_code) BETWEEN 1 AND 1024)
        OR
        (decision_kind IN (2, 3)
            AND category_code IS NULL AND confidence_code IS NULL
            AND rule_id IS NULL AND rule_version IS NULL
            AND evidence_code IS NULL)
    )
);

CREATE TABLE frozen_attribution_competitor (
    decision_id INTEGER NOT NULL
        REFERENCES frozen_attribution_decision(decision_id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
    rule_id BLOB NOT NULL
        CHECK(typeof(rule_id) = 'blob' AND length(rule_id) BETWEEN 1 AND 1024),
    PRIMARY KEY(decision_id, ordinal),
    UNIQUE(decision_id, rule_id)
) WITHOUT ROWID;

CREATE TABLE historical_observation_batch (
    batch_id INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_run_id TEXT NOT NULL UNIQUE
        REFERENCES scan_run(id) ON DELETE RESTRICT,
    stream_id_utf8 BLOB NOT NULL
        CHECK(typeof(stream_id_utf8) = 'blob'
            AND length(stream_id_utf8) BETWEEN 1 AND 4096),
    scope_key INTEGER NOT NULL
        REFERENCES historical_scope(scope_key) ON DELETE RESTRICT,
    root_subject_key INTEGER NOT NULL
        REFERENCES historical_subject(subject_key) ON DELETE RESTRICT,
    volume_id BLOB NOT NULL
        CHECK(typeof(volume_id) = 'blob' AND length(volume_id) BETWEEN 1 AND 4096),
    mount_generation_id BLOB NOT NULL
        CHECK(typeof(mount_generation_id) = 'blob'
            AND length(mount_generation_id) BETWEEN 1 AND 4096),
    coverage_epoch_id BLOB NOT NULL
        CHECK(typeof(coverage_epoch_id) = 'blob'
            AND length(coverage_epoch_id) BETWEEN 1 AND 4096),
    path_semantics_version INTEGER NOT NULL CHECK(path_semantics_version > 0),
    measurement_semantics_version INTEGER NOT NULL
        CHECK(measurement_semantics_version > 0),
    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0)
);

CREATE TABLE historical_observation_frame (
    frame_id INTEGER PRIMARY KEY,
    batch_id INTEGER NOT NULL
        REFERENCES historical_observation_batch(batch_id) ON DELETE RESTRICT,
    metric INTEGER NOT NULL CHECK(metric IN (1, 2)),
    UNIQUE(batch_id, metric)
);

CREATE TABLE historical_observation_node (
    node_id INTEGER PRIMARY KEY AUTOINCREMENT,
    batch_id INTEGER NOT NULL
        REFERENCES historical_observation_batch(batch_id) ON DELETE RESTRICT,
    subject_key INTEGER NOT NULL
        REFERENCES historical_subject(subject_key) ON DELETE RESTRICT,
    location_key INTEGER NOT NULL
        REFERENCES historical_location(location_key) ON DELETE RESTRICT,
    parent_node_id INTEGER
        REFERENCES historical_observation_node(node_id)
        DEFERRABLE INITIALLY DEFERRED,
    observed_at_ms INTEGER NOT NULL CHECK(observed_at_ms >= 0),
    direct_children_coverage INTEGER NOT NULL
        CHECK(direct_children_coverage IN (1, 2, 3)),
    classification_decision_id INTEGER
        REFERENCES frozen_attribution_decision(decision_id) ON DELETE RESTRICT,
    UNIQUE(batch_id, subject_key),
    UNIQUE(batch_id, location_key)
);

CREATE TABLE historical_metric_endpoint (
    node_id INTEGER NOT NULL
        REFERENCES historical_observation_node(node_id) ON DELETE RESTRICT,
    metric INTEGER NOT NULL CHECK(metric IN (1, 2)),
    frame_id INTEGER NOT NULL
        REFERENCES historical_observation_frame(frame_id) ON DELETE RESTRICT,
    state_kind INTEGER NOT NULL CHECK(state_kind IN (1, 2, 3)),
    bytes INTEGER CHECK(bytes IS NULL OR bytes >= 0),
    measurement_coverage INTEGER CHECK(measurement_coverage IN (1, 2)),
    unknown_reason_code INTEGER
        CHECK(unknown_reason_code IS NULL OR unknown_reason_code BETWEEN 1 AND 6),
    PRIMARY KEY(node_id, metric),
    CHECK(
        (state_kind = 1 AND bytes IS NOT NULL
            AND measurement_coverage IS NOT NULL
            AND unknown_reason_code IS NULL)
        OR
        (state_kind = 2 AND bytes IS NULL
            AND measurement_coverage IS NULL
            AND unknown_reason_code IS NULL)
        OR
        (state_kind = 3 AND bytes IS NULL
            AND measurement_coverage IS NULL
            AND unknown_reason_code IS NOT NULL)
    )
) WITHOUT ROWID;

CREATE TABLE historical_endpoint_stable_identity (
    node_id INTEGER PRIMARY KEY
        REFERENCES historical_observation_node(node_id) ON DELETE RESTRICT,
    guard_kind INTEGER NOT NULL CHECK(guard_kind IN (1, 2)),
    generation_token_utf8 BLOB,
    birth_seconds INTEGER,
    birth_nanoseconds INTEGER,
    node_kind INTEGER NOT NULL CHECK(node_kind = 1),
    link_status INTEGER NOT NULL CHECK(link_status IN (1, 2, 3)),
    CHECK(
        (guard_kind = 1 AND typeof(generation_token_utf8) = 'blob'
            AND length(generation_token_utf8) BETWEEN 1 AND 4096
            AND birth_seconds IS NULL AND birth_nanoseconds IS NULL)
        OR
        (guard_kind = 2 AND generation_token_utf8 IS NULL
            AND birth_seconds >= 0
            AND birth_nanoseconds BETWEEN 0 AND 999999999)
    )
) WITHOUT ROWID;

CREATE TABLE historical_observation_frame_commit (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    frame_id INTEGER NOT NULL UNIQUE
        REFERENCES historical_observation_frame(frame_id) ON DELETE RESTRICT,
    root_node_id INTEGER NOT NULL,
    root_metric INTEGER NOT NULL CHECK(root_metric IN (1, 2)),
    endpoint_count INTEGER NOT NULL CHECK(endpoint_count > 0),
    committed_at_ms INTEGER NOT NULL
        CHECK(committed_at_ms >= 0),
    retention_anchor_ms INTEGER NOT NULL
        CHECK(retention_anchor_ms BETWEEN 0 AND 9223372034262775807),
    expires_at_ms INTEGER NOT NULL,
    CHECK(expires_at_ms = retention_anchor_ms + 2592000000),
    FOREIGN KEY(root_node_id, root_metric)
        REFERENCES historical_metric_endpoint(node_id, metric)
        ON DELETE RESTRICT
);

CREATE TABLE historical_calibration_receipt (
    scan_run_id TEXT PRIMARY KEY
        REFERENCES scan_run(id) ON DELETE RESTRICT,
    request_format_version INTEGER NOT NULL CHECK(request_format_version = 1),
    canonical_request_sha256 BLOB NOT NULL
        CHECK(typeof(canonical_request_sha256) = 'blob'
            AND length(canonical_request_sha256) = 32),
    outcome INTEGER NOT NULL CHECK(outcome IN (1, 2)),
    logical_sequence INTEGER UNIQUE
        REFERENCES historical_observation_frame_commit(sequence) ON DELETE RESTRICT,
    allocated_sequence INTEGER UNIQUE
        REFERENCES historical_observation_frame_commit(sequence) ON DELETE RESTRICT,
    committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0),
    retention_anchor_ms INTEGER NOT NULL CHECK(retention_anchor_ms >= 0),
    expires_at_ms INTEGER NOT NULL CHECK(expires_at_ms >= 0),
    CHECK(
        (outcome = 1 AND logical_sequence IS NOT NULL
            AND allocated_sequence IS NOT NULL
            AND allocated_sequence = logical_sequence + 1
            AND retention_anchor_ms <= 9223372034262775807
            AND expires_at_ms = retention_anchor_ms + 2592000000)
        OR
        (outcome = 2 AND logical_sequence IS NULL AND allocated_sequence IS NULL
            AND retention_anchor_ms = committed_at_ms
            AND retention_anchor_ms <= 9223372036249975807
            AND expires_at_ms = retention_anchor_ms + 604800000)
    )
) WITHOUT ROWID;

CREATE TABLE historical_disabled_calibration_receipt (
    receipt_id BLOB PRIMARY KEY
        CHECK(typeof(receipt_id) = 'blob' AND length(receipt_id) = 16),
    request_format_version INTEGER NOT NULL CHECK(request_format_version = 1),
    canonical_request_sha256 BLOB NOT NULL
        CHECK(typeof(canonical_request_sha256) = 'blob'
            AND length(canonical_request_sha256) = 32),
    committed_at_ms INTEGER NOT NULL
        CHECK(committed_at_ms BETWEEN 0 AND 9223372036249975807),
    expires_at_ms INTEGER NOT NULL
        CHECK(expires_at_ms = committed_at_ms + 604800000)
) WITHOUT ROWID;

CREATE TABLE historical_observation_baseline_checkpoint (
    frame_sequence INTEGER PRIMARY KEY
        REFERENCES historical_observation_frame_commit(sequence) ON DELETE RESTRICT,
    checkpoint_kind INTEGER NOT NULL CHECK(checkpoint_kind IN (1, 2)),
    committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0)
);

CREATE TABLE historical_projection_work (
    work_id INTEGER PRIMARY KEY AUTOINCREMENT,
    baseline_sequence INTEGER NOT NULL
        REFERENCES historical_observation_frame_commit(sequence) ON DELETE RESTRICT,
    comparison_sequence INTEGER NOT NULL UNIQUE
        REFERENCES historical_observation_frame_commit(sequence) ON DELETE RESTRICT,
    algorithm_version INTEGER NOT NULL CHECK(algorithm_version = 1),
    ranking_policy_version INTEGER NOT NULL CHECK(ranking_policy_version = 1),
    positive_limit INTEGER NOT NULL CHECK(positive_limit BETWEEN 1 AND 100),
    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
    CHECK(comparison_sequence > baseline_sequence)
);

CREATE TABLE historical_finding_projection (
    projection_id INTEGER PRIMARY KEY AUTOINCREMENT,
    work_id INTEGER NOT NULL UNIQUE
        REFERENCES historical_projection_work(work_id) ON DELETE RESTRICT,
    format_version INTEGER NOT NULL CHECK(format_version = 1),
    canonical_result_sha256 BLOB NOT NULL
        CHECK(typeof(canonical_result_sha256) = 'blob'
            AND length(canonical_result_sha256) = 32),
    truncated_positive_count INTEGER NOT NULL CHECK(truncated_positive_count >= 0),
    committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0)
);

CREATE TABLE historical_projection_checkpoint (
    work_id INTEGER PRIMARY KEY,
    committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0),
    FOREIGN KEY(work_id)
        REFERENCES historical_projection_work(work_id) ON DELETE RESTRICT,
    FOREIGN KEY(work_id)
        REFERENCES historical_finding_projection(work_id) ON DELETE RESTRICT
);

CREATE TABLE historical_finding (
    finding_id INTEGER PRIMARY KEY AUTOINCREMENT,
    projection_id INTEGER NOT NULL
        REFERENCES historical_finding_projection(projection_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
    finding_key_sha256 BLOB NOT NULL UNIQUE
        CHECK(typeof(finding_key_sha256) = 'blob' AND length(finding_key_sha256) = 32),
    draft_sha256 BLOB NOT NULL
        CHECK(typeof(draft_sha256) = 'blob' AND length(draft_sha256) = 32),
    baseline_node_id INTEGER NOT NULL,
    baseline_metric INTEGER NOT NULL CHECK(baseline_metric IN (1, 2)),
    comparison_node_id INTEGER NOT NULL,
    comparison_metric INTEGER NOT NULL CHECK(comparison_metric IN (1, 2)),
    kind INTEGER NOT NULL CHECK(kind BETWEEN 1 AND 5),
    inclusive_delta_bytes INTEGER NOT NULL,
    ranking_contribution_bytes INTEGER,
    movement_ancestor_finding_id INTEGER
        REFERENCES historical_finding(finding_id) DEFERRABLE INITIALLY DEFERRED,
    expires_at_ms INTEGER NOT NULL,
    UNIQUE(projection_id, ordinal),
    CHECK(baseline_metric = comparison_metric),
    CHECK(baseline_node_id != comparison_node_id),
    FOREIGN KEY(baseline_node_id, baseline_metric)
        REFERENCES historical_metric_endpoint(node_id, metric)
        ON DELETE RESTRICT,
    FOREIGN KEY(comparison_node_id, comparison_metric)
        REFERENCES historical_metric_endpoint(node_id, metric)
        ON DELETE RESTRICT
);

CREATE TABLE historical_finding_positive_rank (
    projection_id INTEGER NOT NULL
        REFERENCES historical_finding_projection(projection_id) ON DELETE CASCADE,
    rank INTEGER NOT NULL CHECK(rank BETWEEN 1 AND 100),
    finding_id INTEGER NOT NULL UNIQUE
        REFERENCES historical_finding(finding_id) ON DELETE CASCADE,
    PRIMARY KEY(projection_id, rank)
) WITHOUT ROWID;

CREATE TABLE historical_finding_reason_count (
    projection_id INTEGER NOT NULL
        REFERENCES historical_finding_projection(projection_id) ON DELETE CASCADE,
    category INTEGER NOT NULL CHECK(category BETWEEN 1 AND 3),
    reason_code INTEGER NOT NULL CHECK(
        (category = 1 AND reason_code BETWEEN 1 AND 30)
        OR (category = 2 AND reason_code BETWEEN 31 AND 34)
        OR (category = 3 AND reason_code BETWEEN 35 AND 38)
    ),
    count INTEGER NOT NULL CHECK(count > 0),
    PRIMARY KEY(projection_id, category, reason_code)
) WITHOUT ROWID;

CREATE TABLE historical_finding_retraction (
    retraction_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    request_format_version INTEGER NOT NULL CHECK(request_format_version = 1),
    request_id BLOB NOT NULL UNIQUE
        CHECK(typeof(request_id) = 'blob' AND length(request_id) = 16),
    canonical_request_sha256 BLOB NOT NULL
        CHECK(typeof(canonical_request_sha256) = 'blob'
            AND length(canonical_request_sha256) = 32),
    retracted_finding_id INTEGER NOT NULL UNIQUE
        REFERENCES historical_finding(finding_id) ON DELETE RESTRICT,
    expected_draft_sha256 BLOB NOT NULL
        CHECK(typeof(expected_draft_sha256) = 'blob'
            AND length(expected_draft_sha256) = 32),
    reason_code INTEGER NOT NULL CHECK(reason_code = 1),
    committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0)
);

CREATE TABLE historical_path_free_gap (
    reason_code INTEGER PRIMARY KEY CHECK(reason_code BETWEEN 1 AND 3),
    first_recorded_at_ms INTEGER NOT NULL CHECK(first_recorded_at_ms >= 0),
    last_recorded_at_ms INTEGER NOT NULL CHECK(last_recorded_at_ms >= first_recorded_at_ms),
    occurrence_count INTEGER NOT NULL CHECK(occurrence_count > 0)
) WITHOUT ROWID;
```

Migration creates exactly one `historical_store_identity` row with 16 nonzero bytes from the operating-system CSPRNG and preserves that row through backup/recovery. A committed Domain `ObservationEndpointID` is not stored redundantly. Inside the final transaction it may be provisionally derived for reload/revalidation, but it must not escape the actor, be persisted as a duplicate string, or be returned before COMMIT succeeds. Its 57-byte lowercase ASCII form is `st11:<32-hex-store-generation>:<16-hex-node-id>:<01-or-02-metric>`. `node_id` is a positive SQLite `AUTOINCREMENT` value rendered as unsigned big-endian hexadecimal; `01` is logical and `02` is allocated. New stores receive a different generation, restored copies retain the original, rolled-back IDs never escape the transaction, and import/merge of independent ledgers is explicitly unsupported until it has a collision policy. The paired API additionally accepts only repository-issued canonical lowercase UUID run IDs; their 16 raw UUID bytes form the disabled receipt ID without hashing or retaining a foreign key to the path-bearing scan row. Legacy finalization keeps its existing broader run-ID compatibility.

### Exact explicit indexes

The physical prototype includes these names and no path/token index:

- `historical_batch_scope` on batch `(scope_key, batch_id)`;
- `historical_batch_root_subject` on batch `(root_subject_key)`;
- `historical_node_subject` on node `(subject_key)`;
- `historical_node_location` on node `(location_key)`;
- `historical_node_parent` partial on non-null `(parent_node_id)`;
- `historical_node_classification_decision` partial on non-null `(classification_decision_id)`;
- `historical_metric_endpoint_frame` on metric endpoint `(frame_id, node_id)`;
- `historical_frame_commit_root_endpoint` on commit `(root_node_id, root_metric)`;
- `node_current_last_scan_run` on the existing `node_current(last_scan_run_id)` foreign-key child;
- `historical_projection_work_baseline` on work `(baseline_sequence)`;
- the table-level `UNIQUE(projection_id, ordinal)` autoindex serves finding reconstruction order; Task 2 records its plan and must not add a duplicate explicit index;
- `historical_finding_baseline_endpoint` and `historical_finding_comparison_endpoint` on the respective `(node_id, metric)` pairs for `RESTRICT` checks;
- `historical_finding_movement_ancestor` partial on non-null movement ancestor;
- `historical_retraction_target` is supplied by the column-level unique constraint.

Task 2 uses `dbstat` to justify every retained index. An index that neither enforces an invariant nor changes a measured query plan is removed before v11 freezes.

### Exact trigger names and responsibilities

- `historical_node_validate_insert`, `historical_metric_endpoint_validate_insert`, and `historical_stable_identity_validate_insert`: canonical parent-before-child insertion with same-batch parent; node scope/location membership; each metric endpoint's frame/batch/metric membership and local state shape; if a sibling metric row already exists, reject a state/coverage/reason mismatch; stable evidence basis/guard shape. These row triggers never require a not-yet-inserted sibling.
- `historical_frame_commit_validate`: before the first marker, both frames and both endpoint sets already exist. Bidirectional `NOT EXISTS` plus counts require every batch node to own exactly `(node_id, logical)` and `(node_id, allocated)`, each in the matching frame, with identical state/coverage/reason; present-only classification and absent/unknown direct-child shape hold. The batch has exactly one `parent_node_id IS NULL` node; that node's subject equals `batch.root_subject_key`, it equals the marker's `root_node_id`, and its root metric/frame/state are valid. Raw subject ID, raw location ID, and raw path bytes are unique per batch (not merely surrogate-key unique); ambiguous competitor count/order is canonical; complete direct-parent absence proof resolves as `(parent_node_id, same metric)`; and `retention_anchor_ms` equals the batch's minimum node observation time. No raw parent endpoint ID is stored.
- `historical_calibration_receipt_validate`: a published main receipt references consecutive logical then allocated sequences from the same batch/scan run, uses that batch's earliest node observation as its anchor, and expires at anchor + 2,592,000,000 ms. A superseded main receipt uses DB-owned commit time and expires exactly 604,800,000 ms later; SQL can therefore revalidate its shape/arithmetic without nonexistent candidate rows. Published/superseded canonical digests cover every request field using strict length-prefixing, and repository retry revalidates them. `historical_disabled_calibration_receipt_validate` accepts the canonical 16-byte UUID receipt ID, DB-owned commit time, and the same seven-day TTL without any `scan_run` FK. Main and disabled insert triggers compare canonical UUID bytes and reject the same run identity appearing in both tables. The disabled digest has a separate domain tag and covers only format version, policy outcome, dirty revision/reason bits/optional cursor, and report coverage/entry/directory scalar counts; it excludes every unconstrained string, candidate node, work path, stream/run value, and the necessarily empty complete-report gap list. Once the disabled receipt exists, those excluded fields are ignored on retry; a different run ID is a separate operation, while changed included scalar evidence is immutable conflict.
- `historical_baseline_validate_series` and `historical_work_validate_pair`: baseline/work mutual exclusion, same scope/metric, immediate predecessor, and v1 versions.
- `historical_finding_validate_insert`: both native `(node_id, metric)` endpoint FKs belong to the work frames, movement ancestor belongs to the same projection, stored expiry is the minimum frame expiry, and normalized columns match v1 shape.
- `historical_rank_validate_projection`: ranked finding belongs to the same projection.
- `historical_retraction_validate_target`: target exists, has not already been retracted, expected draft digest matches, and only `evidence_invalidated` is accepted. Schema v11 contains no successor/supersession column or trigger; adding replacement semantics requires a later schema migration.
- Immutable update triggers are exactly `historical_store_identity_immutable_update`, `historical_scope_immutable_update`, `historical_subject_immutable_update`, `historical_location_immutable_update`, `historical_attribution_decision_immutable_update`, `historical_attribution_competitor_immutable_update`, `historical_batch_immutable_update`, `historical_frame_immutable_update`, `historical_node_immutable_update`, `historical_metric_endpoint_immutable_update`, `historical_stable_identity_immutable_update`, `historical_frame_commit_immutable_update`, `historical_calibration_receipt_immutable_update`, `historical_disabled_calibration_receipt_immutable_update`, `historical_baseline_checkpoint_immutable_update`, `historical_projection_work_immutable_update`, `historical_projection_immutable_update`, `historical_projection_checkpoint_immutable_update`, `historical_finding_immutable_update`, `historical_rank_immutable_update`, `historical_reason_count_immutable_update`, and `historical_retraction_immutable_update`. The ordinary actor connection denies UPDATE/DELETE against immutable v11 tables through a scoped SQLite authorizer; only the actor's exact retention operation temporarily enables the named delete graph. `historical_retention_policy` is the sole mutable user setting, and `historical_path_free_gap` is the sole bounded mutable health aggregate; neither is causal evidence.

The migration test freezes one canonical schema-object digest. It selects every non-`sqlite_%` table, explicit index, and trigger from `sqlite_schema`; sorts rows by the raw UTF-8 bytes of `(type, name, tbl_name)`; and feeds a domain tag plus each field as an unsigned 64-bit big-endian length followed by the exact UTF-8 bytes into SHA-256. SQL `NULL` uses a distinct one-byte marker. Table SQL covers implicit UNIQUE/autoindex definitions, so unstable autoindex names are neither selected nor hashed. Fresh, migrated, fixture, and recovery paths call this one implementation rather than independently normalizing SQL.

### Cross-row trust boundary

The repository constructs the complete candidate with Application validators before SQL, but does not trust it as detached from the calibration transaction. The request/run/stream/work revision must match the persisted running scan; every present candidate path/metric/coverage must match exactly one staged aggregate and every staged aggregate must be represented, while an absent node must resolve to the immediate prior v11 frame, be missing from staging, and retain complete current direct-parent proof. Report counts and root/region context are cross-checked before any historical insert; evidence that cannot be coupled becomes a typed gap, not an authoritative frame. After inserting normalized rows but before the marker, the repository reloads and compares the endpoint-ID-free candidate. Only the markers supply positive sequences; immediately afterward, still inside the transaction, it provisionally derives endpoint IDs, reconstructs both committed `HistoricalFindingObservationFrame` values, and compares them with the candidate materialization. Those values remain actor-local until COMMIT succeeds. Read/projection boundaries reconstruct again. SQL constraints/triggers independently reject orphan/cross-frame references and obvious state contradictions. SQLite does not attempt to reproduce component-aware path-parent logic; corrupt bytes that bypass the public writer still fail Application reconstruction and recovery qualification.

The actor remains the sole transaction/connection owner. Public conformance methods and the private `BEGIN`/`COMMIT`/rollback state machine stay in `SQLiteEventJournalRepository.swift`; they obtain the actor-isolated handle through its existing private seam and invoke an internal `SQLiteHistoricalFindingStore(handle:)` for statement-level operations. The store cannot escape the actor, cannot start a transaction, and exposes no general connection callback. This avoids weakening the current private connection merely to split source files.

Task 4 freezes typed failure points for calibration-frame, projection, retraction, retention, and each post-COMMIT/pre-receipt edge, even when later tasks first consume them. A post-COMMIT ACK-loss hook executes after the transaction's rollback-catching `do/catch` has ended; it must never attempt `ROLLBACK` after a successful COMMIT. Tasks 5–7 include `SQLiteEventJournalRepository.swift` in their owned files so they can add public actor methods and consume these private seams without opening the raw handle to cross-file extensions or across `await`.

## Application persistence contract

```swift
public enum HistoricalPairedObservationStateCandidate: Sendable, Equatable {
    case present(
        logicalBytes: ByteCount,
        allocatedBytes: ByteCount,
        measurementCoverage: ObservationCoverage
    )
    case absent
    case unknown(ObservationUnavailabilityReason)
}

public struct HistoricalPairedObservationNodeCandidate: Sendable, Equatable {
    public let subjectID: SubjectID
    public let identityBasis: ObservationSubjectIdentityBasis
    public let parentSubjectID: SubjectID?
    public let locationID: ObservationLocationID
    public let path: String
    public let displayName: String
    public let observedAt: ObservationInstant
    public let state: HistoricalPairedObservationStateCandidate
    public let directChildrenCoverage: ObservationCoverage
    public let classification: VersionedAttributionDecision?
    public let stableIdentityEvidence: HistoricalFindingStableIdentityEvidence?
}

public struct HistoricalPairedObservationCandidate: Sendable, Equatable {
    public let rootSubjectID: SubjectID
    public let rootPath: String
    public let nodes: [HistoricalPairedObservationNodeCandidate]
    public let scopeID: ScopeID
    public let volumeID: ObservationVolumeID
    public let mountGenerationID: ObservationMountGenerationID
    public let coverageEpochID: ObservationCoverageEpochID
    public let pathSemanticsVersion: ObservationSemanticsVersion
    public let measurementSemanticsVersion: ObservationSemanticsVersion
}

public struct HistoricalCalibrationFinalizationRequest: Sendable, Equatable {
    public let runID: CalibrationRunID
    public let report: CalibrationReport
    public let workItem: DirtyRegionWorkItem
    public let streamID: EventStreamID
    public let observation: HistoricalPairedObservationCandidate
}

public enum HistoricalCalibrationCommitDisposition: Sendable, Equatable {
    case newlyCommitted
    case alreadyCommitted
}

public struct HistoricalCalibrationCommit: Sendable, Equatable {
    public let disposition: HistoricalCalibrationCommitDisposition
    public let logical: HistoricalObservationFrameCommit
    public let allocated: HistoricalObservationFrameCommit
}

public enum HistoricalCalibrationFinalizationOutcome: Sendable, Equatable {
    case published(HistoricalCalibrationCommit)
    case superseded
    case historyDisabled
}

public struct HistoricalPathHistoryPolicy: Sendable, Equatable, Hashable {
    public let retentionDays: Int // validated to 0...30; zero means history off
}

public enum HistoricalPathHistoryAvailability: Sendable, Equatable {
    case historyDisabled
    case baselineUnavailable
    case available
}

public struct HistoricalFindingEvidenceInvalidationCommand: Sendable, Equatable {
    public let requestID: HistoricalRetractionRequestID
    public let findingID: HistoricalFindingRecordID
    public let expectedDraftSHA256: HistoricalEvidenceDigest

    // The internal Application integrity authorizer is the only same-file
    // caller after it validates a typed integrity failure.
    fileprivate init(
        requestID: HistoricalRetractionRequestID,
        storedAuditRecord: HistoricalFindingAuditRecord
    ) {
        self.requestID = requestID
        findingID = storedAuditRecord.finding.recordID
        expectedDraftSHA256 = storedAuditRecord.draftSHA256
    }
}

public struct EffectiveHistoricalFinding: Sendable, Equatable {
    public let recordID: HistoricalFindingRecordID
    public let projectionID: HistoricalProjectionRecordID
    public let comparisonSequence: ObservationCommitSequence
    public let positiveRank: Int?
    public let draft: HistoricalFindingDraft
}

public struct HistoricalFindingAuditRecord: Sendable, Equatable {
    public let finding: EffectiveHistoricalFinding
    public let draftSHA256: HistoricalEvidenceDigest
    public let retraction: HistoricalFindingRetractionRecord?
}

public struct HistoricalFindingQueryLimit: Sendable, Equatable, Hashable {
    public let rawValue: Int // validated to 1...1000
}

public protocol HistoricalFindingPersistenceRepository: EventJournalRepository {
    func finalizeCalibrationWithHistoricalFrames(
        _ request: HistoricalCalibrationFinalizationRequest
    ) async throws -> HistoricalCalibrationFinalizationOutcome

    func historicalObservationFrame(
        sequence: ObservationCommitSequence
    ) async throws -> HistoricalFindingObservationFrame?

    func nextHistoricalProjectionWork() async throws -> HistoricalProjectionWork?

    func commitHistoricalProjection(
        _ result: HistoricalFindingGenerationResult,
        for work: HistoricalProjectionWork
    ) async throws -> HistoricalProjectionCommitOutcome

    func historicalFindingAuditRecord(
        id: HistoricalFindingRecordID
    ) async throws -> HistoricalFindingAuditRecord?

    func effectiveHistoricalFindings(
        for scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence,
        limit: HistoricalFindingQueryLimit
    ) async throws -> [EffectiveHistoricalFinding]

    func historicalPathHistoryPolicy() async throws -> HistoricalPathHistoryPolicy

    func historicalPathHistoryAvailability(
        for scopeID: ScopeID
    ) async throws -> HistoricalPathHistoryAvailability

    func setHistoricalPathHistoryPolicy(
        _ policy: HistoricalPathHistoryPolicy
    ) async throws
}

package protocol HistoricalFindingIntegrityReconciliationRepository: Sendable {
    func commitEvidenceInvalidation(
        _ command: HistoricalFindingEvidenceInvalidationCommand
    ) async throws -> HistoricalRetractionCommitOutcome
}
```

Candidate validation canonicalizes nodes by byte-exact `SubjectID`, validates the complete rooted tree and path/display boundaries, requires present/absent/unknown state shape, and structurally freezes all non-metric evidence once. A present node carries exactly one logical and one allocated byte count under the same measurement coverage; an absent non-root node derives each future absence reference from its direct parent subject; unknown carries one typed reason. No endpoint ID, database key, sequence, or metric-specific parent ID enters the candidate. After SQLite assigns node IDs and commit sequences, the adapter derives both endpoint-ID sets from `(store generation, node ID, metric)`, rematerializes every endpoint through public validated initializers, reconstructs both frames, and compares them with the candidate before returning.

The public repository has no retraction mutation. An internal `HistoricalFindingIntegrityReconciliationAuthorizer` accepts only typed ledger/projection-integrity failures plus a stored `HistoricalFindingAuditRecord`; it rejects an already retracted record and uses the command's same-file `fileprivate` initializer to copy that record's finding ID and `draftSHA256`. The command is not `Codable` and has no public, package, or ordinary internal memberwise initializer. Only the package-scoped reconciliation port accepts it, so the app/UI target, classifier, user cleanup, and ordinary scan paths cannot manufacture or invoke evidence invalidation. SQLite still checks the target, stored digest, and request idempotency inside the transaction.

Effective queries constrain the finding comparison sequence, while a retraction always reflects current validity; v11 does not claim an as-of correction view. Results order by comparison sequence descending, present positive rank ascending before unranked rows, then the existing binary `HistoricalFindingKey`, then record ID. A digest is never used as an ordering surrogate. Because v11 fixes algorithm/ranking to 1 and every endpoint string in one store has the same prefix, the SQL-equivalent key is baseline node ID/metric ascending, comparison node ID/metric ascending, kind in raw-UTF-8 order `appearance, decrease, disappearance, growth, move`, then joined baseline/comparison catalog version with nil encoded as zero, and finding ID. The query applies `LIMIT` only after this complete order; rehydration rechecks the resulting order against `HistoricalFindingKey`. `limit` is restricted to `1...1000`.

This plan document is reviewed, committed, and pushed as its own planning artifact before the prerequisite task begins. That plan-add commit is the cumulative privacy checker's durable bootstrap boundary; the checker never has to discover an uncommitted plan file.

## Prerequisite Task: Freeze history-off/retraction decisions and install the cumulative privacy gate

**Files**

- Modify `docs/superpowers/plans/2026-08-11-sqlite-v11-historical-ledger.md` only to incorporate prerequisite review corrections
- Modify `docs/architecture/decisions/ADR-004-sqlite-persistence-and-retention.md`
- Modify `docs/architecture/decisions/ADR-006-immutable-observations-and-findings.md`
- Modify `docs/architecture/decisions/ADR-006-immutable-observations-and-findings.zh-CN.md`
- Modify `docs/architecture/technical-architecture.md`
- Modify `Makefile`
- Modify `.github/workflows/ci.yml`
- Create `Scripts/check-historical-ledger-privacy.sh`
- Create `Scripts/Tests/check-historical-ledger-privacy-tests.sh`

- [x] Amend ADR-004 before implementing history-off: ordinary time retention still never silently removes the active authorized baseline, while explicit History Off removes all baseline snapshots/roots after confirmation, retains current authorization/current-state operation, presents typed `history disabled / baseline unavailable` state, and requires a fresh authorized baseline after history is re-enabled. Keep Clear History distinct: it follows the privacy baseline's full database/checkpoint/cache reset, does not retain database-backed authorization or current state, and remains a separate release-blocking workflow outside Task 7.
- [x] Add matching English/Chinese decision text that distinguishes an immutable finding, a no-replacement `evidence_invalidated` retraction, and a future replacement. Retraction may be requested only by a typed reconciliation/integrity workflow with the exact stored draft digest; it is never inferred from a later missing path, rename hint, size match, classifier upgrade, or user cleanup action.
- [x] Make that authorization structural: the public history repository exposes no retraction mutation; an Application-internal authorizer is the only constructor of a non-`Codable` command using a typed integrity failure and the stored audit record, and a separate package-scoped persistence port accepts it. Define current-effective query semantics, an audit read that still exposes the original finding plus retraction record, UI wording/visibility, idempotency, and retention (the retraction expires with its target). State that v11 retraction does not satisfy the still-open replacement/supersession obligation.
- [x] Update the technical-architecture invariant so it no longer presents v11 supersession as implemented or required; distinguish the independent retraction from a future corrected successor.
- [x] Write `Scripts/Tests/check-historical-ledger-privacy-tests.sh` first, then run `bash Scripts/Tests/check-historical-ledger-privacy-tests.sh` and confirm the initial RED only because the production checker is absent. Every self-contained temporary repository commits this plan path and exercises the same automatic plan-add-parent bootstrap as production; no environment or CLI base override exists. Cases cover cumulative/merge/replacement-ref history, staged/unstaged/untracked files, enumeration/tool failures, secret families, real-user absolute paths, direct diagnostic sinks and aliases, sensitive filenames, safe synthetic fixtures, hidden index flags, resource bounds, exact frozen-v1 fixture closure, regular-file enforcement, and fail-closed rejection of every future manifest format before Task 8's independent verifier lands.
- [x] Implement the checker. In the real repository it discovers the unique commit that first added this plan and scans from that commit's parent through `HEAD`, then unions staged, unstaged, and untracked files; later commits can never disappear from its scope. It rejects shallow/grafted/replacement-ref history, bounds every producer while streaming NUL-delimited paths—including deletions—before temporary materialization, and revalidates a bounded worktree snapshot after reading. It never embeds or reports a real username/email/path literal, keeps secret scanning separate from synthetic-path review, and uses the Swift compiler parse tree—not receiver-shaped source regexes—to ban direct diagnostic calls and function references until a reviewed path-free wrapper exists; comments and string literals remain inert. Because parse output has no resolved receiver types, member names such as `.info`, `.error`, `.raise`, and signposter methods are a deliberate fail-closed over-approximation: an unrelated method with one of those names must be renamed or routed through the reviewed wrapper, while global-only symbols remain separate so ordinary members such as `Data.write` are accepted. This prerequisite accepts only the regular v1 fixtures and byte-identical manifest already present at the plan boundary; it rejects every new binary/manifest format rather than treating self-authored hashes or a generator path as provenance. Task 8 must install independent SQLite qualification and deterministic regeneration before v2 is admitted.
- [x] Add both the checker contract self-test and the production checker to `make verify`, and configure GitHub Actions checkout with full history (`fetch-depth: 0`). A shallow checkout or Swift parser/tool producer failure is an infrastructure failure, never a successful empty scan or a privacy finding.
- [x] Obtain independent product/architecture/privacy review before any Application or schema type is added. If the amendment is not accepted, remove retraction from this plan instead of silently implementing it.
- [x] Run `bash Scripts/Tests/check-historical-ledger-privacy-tests.sh` and the common slice gate, stage only the nine named files, commit `明确历史关闭撤回边界并建立隐私门禁`, and `git push`.

## Task 1: Add sequence-free candidates and the Application port

**Files**

- Create `Packages/SpaceTraceKit/Sources/SpaceTraceApplication/History/HistoricalFindingPersistence.swift`
- Create `Packages/SpaceTraceKit/Tests/SpaceTraceApplicationTests/HistoricalFindingPersistenceTests.swift`

- [ ] Write RED tests for endpoint-ID/sequence-free paired candidate construction, canonical input order, byte-distinct Unicode identities/paths, invalid trees, root absence, exact logical+allocated value membership, absent direct-parent derivation, state/classification/stable-evidence contradictions, repository-issued canonical lowercase UUID eligibility and 16-byte receipt-ID conversion for the paired API, typed finalization outcomes including history-disabled, typed `HistoricalPathHistoryAvailability` states (`historyDisabled`, `baselineUnavailable`, `available`), `HistoricalPathHistoryPolicy` bounds `0...30`, and query limit validation. Add an API/source audit proving candidates expose no database key, `Codable`, or serialization surface; the public repository exposes no retraction mutation; the evidence-invalidation command has only a same-file `fileprivate` initializer; and only the package-scoped reconciliation port accepts it.
- [ ] Confirm RED with `swift test --package-path Packages/SpaceTraceKit --filter HistoricalFindingPersistenceTests`.
- [ ] Implement the paired candidate with one canonical shared node tree. It may reuse frame validation internally with nonescaping provisional IDs/sequences, but none may become public candidate state. A narrowly `package`-visible (not `public`, not `Codable`) commit materializer requires a 16-byte store generation, a complete one-to-one subject→positive-node-ID assignment, and two positive consecutive sequences; it derives the exact v11 endpoint-ID strings, builds both frames through public initializers, and rejects missing/duplicate/reused assignments. Persistence may invoke it inside its actor transaction for validation, but no materialized endpoint/frame may escape before COMMIT.
- [ ] Keep the port declaration source-compatible while implementation is sliced: Tasks 4 through 7 add concrete actor methods without declaring full protocol conformance; Task 7 declares `SQLiteEventJournalRepository: HistoricalFindingPersistenceRepository` only after persisted policy get/set and every other requirement exist. No placeholder/fatal implementation is permitted.
- [ ] Re-run `swift test --package-path Packages/SpaceTraceKit --filter HistoricalFindingPersistenceTests`, then the common slice gate; obtain Application-contract review.
- [ ] Stage only the two files, commit `建立成对历史观测候选与持久化端口`, and `git push`.

## Task 2: Prove and freeze the low-index physical design before migration

**Files**

- Create `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalFindingSchema.swift`
- Modify `Packages/SpaceTraceKit/Sources/SpaceTracePersistenceBenchmark/main.swift`
- Create `Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/SQLiteHistoricalFindingPhysicalDesignTests.swift`
- Modify `docs/engineering/sqlite-history-benchmark.md` with a clearly provisional v11 prototype section

The benchmark unit remains the released workload's **directory sample**, which carries both logical and allocated metrics. Therefore 500,000/1,000,000 retained directory samples materialize 1,000,000/2,000,000 metric endpoint values even if the final physical schema stores shared pair evidence once. The fixed reference time is `2040-02-01T12:00:00Z`; commit follows observation by exactly two seconds. The primary KPI-04 workload is no-change: one scope, 25 observation days inside the preceding 30 days, 20,000/40,000 unchanged directory nodes per paired observation, plus five older identical daily observations that retention must remove so the retained counts are exactly 500k/1M. A second high-frame-count shape uses 100 scopes with 200/400 nodes per scope/day at the same total. Root nodes are included in those counts.

A disposable pre-plan SQLite prototype selected this layout over two rejected alternatives. With 1,000,000 shared nodes, 2,000,000 metric endpoints, FK-supporting indexes, 20% simplified stable evidence, and native composite finding FKs, checkpointed main+WAL+SHM measured 172,863,488 bytes for no-change and 175,910,912 bytes for exact 2% churn; both also stayed below 250,000,000 bytes before maintenance. The prototype used a 40-batch shape instead of the exact 25-day/transition matrix, a 13-byte scope, simplified stable/classification payloads, only `frame_id` in its endpoint-frame index, and no complete legacy-overlap database, whereas the target uses the larger exact distribution, `(frame_id,node_id)`, all triggers/settings/store identity, and existing v10 tables. The prototype script hash was `b8fe7dfd9f9898ddc41fd43dae2f68404bceb1ec5a348a47881d04fc7a63fc92`. These numbers are candidate-selection evidence, not a schema result: Task 2 must reproduce the complete named schema through checked-in Swift code, all scenarios, RSS, and query plans before migration v11 may freeze.

Subject/location IDs are deterministic 20/21-byte ASCII UTF-8 values; scope IDs are 16 bytes; volume UUID is 36 bytes; mount/coverage IDs and generation tokens are 32 bytes. Paths average exactly 64 bytes and display names 16 bytes. The benchmark never stores final endpoint strings: it derives their 57-byte representation from a fixed synthetic 16-byte store generation, DB-owned node ID, and metric only when reconstructing/querying. The primary shape has 96% present, 2% explicit absent, 2% unknown rows; 20% stable identity evidence split equally between birth time and 32-byte generation tokens; 95% shared no-match classification plus 64 fixed 128-byte classified/ambiguous payloads with two 16-byte competitors. The no-change shape has no causal finding drafts after the descriptive baseline. Sensitivity runs repeat with 100% stable evidence and with deterministic 2% daily churn, persisting **all** generator drafts while positive rank remains capped at ten.

Size means the complete app database after retention and checkpoint: current state, scan runs, capacity/history tables, remaining legacy rows during the v10→v11 overlap, every v11 table/index, main, WAL, and SHM. The transition workload keeps the same total directory-sample budget split between aging v10 rows and growing v11 frames; it does not add an unbounded second million. Reports expose legacy/v11 row counts and dictionary cardinalities. A separate baseline-scan benchmark remains responsible for a single scope with up to one million filesystem entries; this 30-day persistence benchmark must not be relabeled as that scan test.

- [ ] Write RED tests that create the complete provisional DDL, assert exact named objects and valid foreign keys, populate smaller semantic fixtures, prove canonical-equivalent byte-distinct identities remain distinct, reject non-BLOB values in BLOB columns, enforce per-field/frame budgets, reject every out-of-range metric/state/coverage/unavailability/category/confidence/reason/category-pair code through direct SQL, and validate every dictionary collision by exact byte comparison rather than hash-only acceptance. Direct-SQL tests also reject a missing sibling metric, mismatched logical/allocated node sets or shape, wrong-frame endpoint, incomplete stable/absence proof, root-subject mismatch, a non-null-parent root or two roots, the same canonical run UUID in main and disabled receipt tables, and wrong-work finding before the first commit marker can make a frame authoritative.
- [ ] Confirm RED with `swift test --package-path Packages/SpaceTraceKit --filter SQLiteHistoricalFindingPhysicalDesignTests`; the failure must be caused by the absent provisional schema/prototype surface, not by an unrelated build error.
- [ ] Add the deterministic 500k/1M prototype mode through the schema's narrow `@_spi(Benchmark)` entry, using the same constants, `secure_delete=ON`, and all proposed indexes/triggers. Report `dbstat` bytes per object, main/WAL/SHM totals after retention and `wal_checkpoint(TRUNCATE)`, peak RSS, insertion time, dictionary cardinalities, and query plans. The SPI exposes only the prototype operation/result, never raw DDL or a database handle.
- [ ] Run primary no-change, high-frame-count, 100%-stable, 2%-churn, and v10→v11 overlap variants with `swift run --package-path Packages/SpaceTraceKit -c release SpaceTracePersistenceBenchmark --mode v11-prototype --directory-samples 500000 --scenario matrix` and the same command with `1000000`. The schema-freeze gate is `<250,000,000` total bytes and `<150,000,000` peak RSS for the released 1M no-change/overlap shapes, empty `foreign_key_check`, `integrity_check=ok`, and no unmeasured index. Sensitivity results are mandatory evidence and may force a product/retention decision, but never replace the no-change KPI. If a release gate fails, revise normalization/indexes and repeat; do not add migration v11.
- [ ] Run `swift test --package-path Packages/SpaceTraceKit --filter SQLiteHistoricalFindingPhysicalDesignTests`, both prototype commands, and the common slice gate; obtain an independent database/benchmark review.
- [ ] Stage only the named files, commit `验证 SQLite v11 低索引物理模型`, and `git push`.

## Task 3: Add strict v11 codec, migration, and schema-object digest

**Files**

- Create `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalFindingCodec.swift`
- Modify `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalFindingSchema.swift`
- Modify `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteEventJournalRepository.swift`
- Create `Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/SQLiteHistoricalFindingMigrationTests.swift`

- [ ] Write RED tests for fresh v11, populated v10→v11 with empty v11 evidence, rollback at `beforeMigrationCommit(version: 11)`, OS-random nonzero store generation injection/persistence through reopen and online backup, distinct generation for an independent new store, node/sequence AUTOINCREMENT non-reuse after committed deletion, pure endpoint-ID derivation vectors, default persisted history-policy row of 30 days and raw-schema `0...30` update/reopen round trips, embedded NUL, NFC/NFD/case-distinct BLOBs, malformed UTF-8, every 1 KiB/4 KiB/64 KiB boundary plus one-byte overflow, frame node/byte budget, every invalid integer discriminant/category pairing, all object names, canonical schema digest, `foreign_key_check`, `integrity_check`, and `PRAGMA secure_delete=ON` on every writable app-repository connection.
- [ ] Confirm RED with `swift test --package-path Packages/SpaceTraceKit --filter SQLiteHistoricalFindingMigrationTests`.
- [ ] Freeze the Task-2-passing DDL/checksum, add explicit migration dispatch from v10, retain pre-migration atomic backup semantics, and never backfill `directory_history_sample` or `node_current`.
- [ ] Re-run `swift test --package-path Packages/SpaceTraceKit --filter SQLiteHistoricalFindingMigrationTests`, then the common slice gate; obtain migration/security review.
- [ ] Stage only the named files, commit `迁移 SQLite v11 不可变历史账本`, and `git push`.

## Task 4: Atomically finalize and rehydrate logical+allocated frames

**Files**

- Create `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalFindingRepository.swift`
- Modify `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteEventJournalRepository.swift`
- Create `Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/HistoricalFindingPersistenceFixtures.swift`
- Create `Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/SQLiteHistoricalObservationLedgerTests.swift`

- [ ] Write RED tests for first paired descriptive baselines; second paired batch creating two work rows; deterministic logical→allocated sequence order under candidate permutation; exact candidate↔running scan/stream/work/root/report/staged-present coupling; first-baseline absence rejection and later absence requiring the immediate prior frame plus missing stage row; all-or-nothing frame/current/history/dirty/run publication; failure after dictionaries/batch/nodes/one metric endpoint set/first metric marker/before work; no endpoint ID returned after rollback; exact committed ID derivation; independent-store generation separation; explicitly rejected cross-batch parent/absence and endpoint/frame mismatch; incomplete absence parent; unknown/partial preservation when supported by non-path typed evidence; wall-clock rollback; expiry anchored to the earliest node observation despite delayed finalization; already-expired candidate rejection without consuming dirty work; byte-exact readback; and legacy finalization creating no v11 evidence. Confirm RED with `swift test --package-path Packages/SpaceTraceKit --filter SQLiteHistoricalObservationLedgerTests`.
- [ ] Add an `afterCalibrationCommitBeforeReturningReceipt` test seam. First call must commit then throw; identical retry before and after reopen returns `.published(.alreadyCommitted)` with identical sequences/counts. Freeze the published/superseded retry matrix for changed stream ID, work region/revision/reasons/cursor, complete-report scalar fields, and candidate: any changed accepted field conflicts, while a distinct valid run ID is an independent operation and an unknown/invalid-state run fails through typed scan-run validation. Complete reports necessarily have no gaps. Superseded expiry is DB-owned commit time + seven days. Task 7 adds the history-disabled matrix because it owns the policy API.
- [ ] Implement one private SQLite finalization primitive parameterized by `.none` or `.paired(observation)`. For paired `running` state, validate dirty revision before any historical insert, compute the exact published/superseded canonical digest, insert normalized dictionaries/batch/shared nodes/two metric endpoint sets, insert commit markers in logical→allocated order, provisionally rematerialize and compare exact frames using the stored generation and DB IDs, add baseline/work and the immutable receipt, execute existing current-state publication, and commit once. The provisional IDs/frames remain actor-local and are returned only after COMMIT. For `completed`/`superseded`, validate stored scan-run context and receipt digest before the running-state guard.
- [ ] Re-run `swift test --package-path Packages/SpaceTraceKit --filter SQLiteHistoricalObservationLedgerTests` and `swift test --package-path Packages/SpaceTraceKit --filter CalibrationPipelineIntegrationTests`, then the common slice gate; obtain concurrency/database review.
- [ ] Stage only the named files, commit `原子提交并恢复双指标历史观测帧`, and `git push`.

This task proves adapter capability only. It deliberately does not change `FileSystemCalibrationPipeline` to construct candidates and does not install a trigger requiring every completed legacy scan to own v11 frames.

## Task 5: Persist crash-idempotent deterministic v1 projections

**Files**

- Modify `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalFindingRepository.swift`
- Modify `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteEventJournalRepository.swift`
- Create `Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/SQLiteHistoricalFindingProjectionTests.swift`

- [ ] Write RED tests for all five finding kinds, empty typed frame suppression, Top 10, reason counts, frozen classifications, movement ancestry, wrong-work/frame/orphan endpoints, endpoint reuse, result tampering, canonical hash collision conflict, crash before checkpoint, commit-success/response-loss retry, conflicting retry, and unsupported algorithm/ranking versions. Prove a new subject without an explicit old absent endpoint remains missing-baseline suppression and never becomes appearance.
- [ ] Confirm RED with `swift test --package-path Packages/SpaceTraceKit --filter SQLiteHistoricalFindingProjectionTests`.
- [ ] Implement pending lookup as lowest comparison sequence work without checkpoint. Reload/revalidate both frames, rerun generator, require exact result and canonical digest, then insert projection/findings/ranks/reasons/checkpoint in one transaction. Findings preserve canonical `ordinal` but are inserted in stable ancestor-before-dependent topological order so the validation trigger can resolve movement ancestry; cyclic/missing ancestry fails before SQL. Store normalized references and digests, not a second path-bearing draft JSON copy. Retry reconstructs the result and fails closed on any mismatch; never use `INSERT OR IGNORE` as success.
- [ ] Re-run `swift test --package-path Packages/SpaceTraceKit --filter SQLiteHistoricalFindingProjectionTests` and `swift test --package-path Packages/SpaceTraceKit --filter HistoricalFinding`, then the common slice gate; obtain projection/durability review.
- [ ] Stage only the named files, commit `持久化可恢复的 v1 历史发现投影`, and `git push`.

## Task 6: Add independent retraction and effective queries

**Files**

- Modify `Packages/SpaceTraceKit/Sources/SpaceTraceApplication/History/HistoricalFindingPersistence.swift`
- Modify `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalFindingRepository.swift`
- Modify `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteEventJournalRepository.swift`
- Create `Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/SQLiteHistoricalFindingRetractionTests.swift`

Retraction digest is SHA-256 over a domain tag, format version, 16-byte request ID, big-endian finding ID, expected draft digest, and length-prefixed reason. Time is DB-owned and excluded. Same request ID plus exact digest returns `.alreadyCommitted`; same request ID with different fields, or same target under a different request, is immutable conflict.

- [ ] Write RED tests proving the internal authorizer accepts only typed ledger/projection-integrity failures, copies the finding ID and exact stored draft digest from an unretracted audit record, and rejects an already retracted record; no UI/user-cleanup/classifier/path/missing-row input can form a command. Then cover valid package-port `evidence_invalidated` commit, commit-success/response-loss retry, stale expected digest, unknown target, duplicate target/request conflict, the complete absence of a v11 successor/supersession schema surface, old payload byte identity, query limit bounds, bytewise stable ordering, and ranked queries excluding retracted rows. Include more candidates than the requested limit with SHA order deliberately opposite endpoint/kind/catalog order, proving SQL applies the exact reconstructed-key order before `LIMIT`.
- [ ] Confirm RED with `swift test --package-path Packages/SpaceTraceKit --filter SQLiteHistoricalFindingRetractionTests`.
- [ ] Implement independent retraction without a fake correcting projection. Keep the mutation off `HistoricalFindingPersistenceRepository`; add the internal authorizer and package-only `HistoricalFindingIntegrityReconciliationRepository` conformance. Implement effective query through comparison sequence with current-validity semantics, plus an audit read that still returns the immutable original, its stored draft digest, and optional retraction; reconstruct every draft before return.
- [ ] Document in API comments/tests that replacement, correction projection, same-pair reprojection, and as-of correction require a future generator registry, frozen correction input, correction work/request, schema migration, crash/retention benchmark, and approved ADR-006 amendment.
- [ ] Re-run `swift test --package-path Packages/SpaceTraceKit --filter SQLiteHistoricalFindingRetractionTests`, then the common slice gate; obtain database/requirements review.
- [ ] Stage only the named files, commit `追加历史发现撤回与有效查询`, and `git push`.

## Task 7: Enforce 30-day graph retention and real disk-full rollback

**Files**

- Modify `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteRetentionPolicy.swift`
- Modify `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteEventJournalRepository.swift`
- Modify `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalFindingRepository.swift`
- Create `Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/SQLiteHistoricalFindingRetentionTests.swift`

- [ ] Write RED tests for exactly 30 days from the earliest endpoint observation retained/30 days+1 ms expired, delayed commit, shorter future policy, persisted `0...30` policy and history-off after reopen, wall-clock rollback, startup retention before the first historical query, old baseline with fresh dependent projection, pending work, mixed scopes, retraction, failure after each dependency tier, repeated retention, and `foreign_key_check`. History-off tests must exercise both adapters: legacy `.none` still atomically publishes `node_current`/dirty/run state but adds no `directory_history_sample`; all prior hourly/daily directory samples, deleted `node_current` tombstones, and authorized baseline snapshots/roots are removed; paired finalization returns an idempotent `.historyDisabled` receipt, still publishes current state, and adds no legacy or v11 historical evidence. The availability read must return `.historyDisabled` after reopen while policy is zero, `.baselineUnavailable` after history is re-enabled but before a fresh authorized baseline commits, and `.available` only after that commit; no optional row or empty result may stand in for these states. Freeze the disabled receipt's separate 16-byte UUID ID, 7-day DB-time expiry, and privacy matrix: changing the ignored candidate, work path, stream, or other excluded string leaves the digest/outcome unchanged; a distinct valid run is an independent operation; changing revision/reasons/cursor/complete-report scalar fields conflicts. After a newer scan releases all current-state references, the old path-bearing `scan_run` must be deletable immediately while the disabled receipt still survives ACK-loss/reopen retry. Operational current truth and continuity state—live `node_current`, unresolved `dirty_region`, watched bookmarks, active mount generation, and path-free volume-capacity history—remain explicitly outside this setting. Scan the active main/WAL/SHM synthetic fixture after logical scrub to prove expired historical paths/display names/location IDs/object guards/payloads are absent while allowlisted operational/current bytes and path-free markers may remain. Confirm RED with `swift test --package-path Packages/SpaceTraceKit --filter SQLiteHistoricalFindingRetentionTests`.
- [ ] Implement effective expiry as `min(stored observation-anchored hard expiry, retentionAnchor + currentPolicyDuration)`. `setHistoricalPathHistoryPolicy` runs on the repository actor; changing to zero and its first graph scrub are one serialized operation, and every legacy/paired finalization checks the persisted singleton inside its write transaction. Zero rejects new historical evidence, suppresses the legacy `recordDirectoryHistory` call, removes legacy directory samples/deleted tombstones/authorized baselines and every path-bearing main receipt, records the separate path-free disabled receipt, and remains off after reopen while current/operational state continues. Implement `historicalPathHistoryAvailability(for:)` from the persisted policy plus the latest authorized baseline commit: zero is `.historyDisabled`; nonzero without a post-enable baseline is `.baselineUnavailable`; only a committed post-enable baseline is `.available`. Preserve source compatibility without a second truth source: add a no-policy `applyRetention(referenceDate:)` that only reads the singleton and make `StorageHistoryRetentionApplying.applyStorageHistoryRetention` call it; keep the old explicit `applyRetention(_ policy:referenceDate:)` only as a deprecated atomic set-policy-then-scrub operation, with no default argument. A persisted off state followed by background/no-policy retention must remain off. In one immediate transaction: compute complete expired v8/v10/v11 historical graphs; upsert global path-free gaps first; delete retractions; ranks/reasons; findings; checkpoints/projections/work; add `retention_rebased` markers to still-retained comparisons that lose predecessors; delete old baselines and published main receipts; delete expired superseded main and disabled receipts (or every main receipt when off); delete frame commits; delete stable evidence and metric endpoints; delete nodes child-before-parent; delete frames and batches; finally delete orphan location/subject/decision/scope dictionaries and only then unreferenced scan runs. Commit, then require a non-busy `wal_checkpoint(TRUNCATE)` with zero remaining frames and verified WAL length before returning logically scrubbed success. Declare full `SQLiteEventJournalRepository: HistoricalFindingPersistenceRepository` conformance here, after policy get/set exists.
- [ ] Build deterministic `SQLITE_FULL` cases. For frame and projection, cap page growth and use a validated multi-page write. For retention, seed at least 512 expired graphs, verify a test-only hook's multi-page padding INSERT grows the database inside the same production retention transaction after global gap upsert but before any deletion, then set `max_page_count` with no freelist so that exact hook returns real `SQLITE_FULL`. The hook is absent in production and may not replace any production statement or error mapping. Verify failure before/during/commit rolls back gap counts, bytes, rows, policy, work/checkpoints, dirty/run/current state and query results; remove the cap, reopen, and retry successfully.
- [ ] Re-run `swift test --package-path Packages/SpaceTraceKit --filter SQLiteHistoricalFindingRetentionTests` and `swift test --package-path Packages/SpaceTraceKit --filter SQLiteEventJournalRepositoryTests`, then the common slice gate; obtain reliability/privacy review.
- [ ] Stage only the named files, commit `约束历史账本保留与磁盘写满恢复`, and `git push`.

## Task 8: Expand released fixtures and read-only recovery evidence

**Files**

- Create `Scripts/Fixtures/generate-released-schema-v10-fixture.sh`
- Create `Scripts/Fixtures/generate-released-schema-v11-fixture.sh`
- Create `Scripts/verify-released-schema-fixtures.sh`
- Modify `Makefile`
- Modify `Scripts/check-historical-ledger-privacy.sh`
- Modify `Scripts/Tests/check-historical-ledger-privacy-tests.sh`
- Create reviewed v10/v11 databases under `Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/`
- Modify `Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/manifest.json`
- Modify `Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/ReleasedSchemaGoldenFixtureTests.swift`
- Modify `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteDatabaseRecovery.swift`
- Create `Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteSensitiveArtifactInventory.swift`
- Modify `Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/SQLiteDatabaseRecoveryTests.swift`

- [ ] Write RED tests for numeric v6...v11 ordering, populated deterministic v10 and v11 fixtures, manifest byte/semantic/schema-object/generator digests with exact JSON types, v10→v11 preservation with empty v11 evidence, v11 reopen semantics, real/injected migration rollback, v10 outranking v9, main/backup corruption matrices, missing/altered index or trigger, FK/logical ledger corruption, duplicate-key/noncanonical frozen JSON, resource bounds, and unsupported v12 with no persistent mutation. The privacy-contract matrix must independently reject a text or opaque `.sqlite`, fixture/manifest/generator symlinks in commit/index/worktree views, a generator-byte drift, self-asserted semantic/schema digests, and a fake generator unrelated to its fixture; removing any case must fail the frozen case-count assertion. Add the production artifact inventory and an exhaustive temp Application-Support fixture covering active main/WAL/SHM, migration backup, online-backup recovery snapshot, quarantined main+WAL bundle, and interrupted temporary files; this expands Task 7's active-database-only scrub proof. Confirm RED with `swift test --package-path Packages/SpaceTraceKit --filter 'ReleasedSchemaGoldenFixtureTests|SQLiteDatabaseRecoveryTests'` and `bash Scripts/Tests/check-historical-ledger-privacy-tests.sh`.
- [ ] Generate fixtures only through explicit scripts under `Scripts/Fixtures/` with fixed synthetic IDs/times, page size 4096, representative rows, checkpoint truncate, secure delete, VACUUM, `quick_check`, `foreign_key_check`, and printed hashes for manual manifest review. Freeze manifest v2 as an exact, duplicate-key-free JSON object: integer `formatVersion: 2`; a bounded `fixtures` array; and, for every entry, exactly integer `schemaVersion`, canonical string `relativePath`, lowercase string `sha256`, canonical string `generatorPath`, lowercase string `generatorSHA256`, positive integer `generatorVersion`, bounded synthetic string `seed`, lowercase string `semanticSHA256`, and lowercase string `schemaObjectSHA256`. `relativePath` must be `v<schemaVersion>/SpaceTrace.sqlite`; `generatorPath` must be `Scripts/Fixtures/generate-released-schema-v<schemaVersion>-fixture.sh`; manifest, fixture, and generator must be regular nonsymlink files with their frozen modes. Add a noninteractive verifier that works only in a disposable directory, requires those exact types and paths, checks the SQLite header plus read-only `quick_check`/`foreign_key_check`/schema allowlist, freezes the committed fixture and generator bytes by their exact digests, independently recomputes semantic and schema-object digests, and regenerates from the frozen seed. The regenerated database must reproduce the exact semantic and schema-object digests; physical page-byte identity is not required across SQLite runtime versions because SQLite 3.50 and 3.51 produce different file encodings for the same logical database. Add a `released-schema-fixtures` Make target and make `verify` depend on it. The privacy checker may admit manifest v2 only after that verifier target is installed and its same-view manifest/fixture/generator closure checks pass; it never accepts self-asserted provenance alone. Golden tests consume committed fixtures for migration behavior and invoke regeneration only into temporary output, never overwrite fixtures in place.
- [ ] Harden recovery to require `quick_check`, empty FK check, supported migration ledger, canonical full schema-object digest, bounded canonical payloads, and ledger reconstruction. Parse backup versions numerically. Only a live SQLite-opened main+WAL(+SHM) artifact set or an atomic SQLite online-backup snapshot may qualify as complete; an isolated copied main file is always labeled incomplete diagnostic evidence because the missing-WAL state cannot be inferred from that file alone. Inventory metadata is path-free and records each app-controlled artifact's earliest sensitive expiry; migration/recovery artifacts are removed at the earliest of successful startup, seven days after creation, or that embedded expiry. Synthetic released fixtures contain no user data.
- [ ] Add the crash edge `retention COMMIT succeeded → process ended before checkpoint`: on reopen, the repository must finish the non-busy WAL truncate and inventory sweep before serving a historical read. The sweep may close only temporary app-owned handles that it opened itself; if another repository/recovery session or external reader keeps the checkpoint busy, return typed scrub-pending state and retry after that reader exits. Never claim arbitrary reader ownership and never report busy state as retention success.
- [ ] Re-run `swift test --package-path Packages/SpaceTraceKit --filter 'ReleasedSchemaGoldenFixtureTests|SQLiteDatabaseRecoveryTests'`, `bash Scripts/verify-released-schema-fixtures.sh`, and `bash Scripts/Tests/check-historical-ledger-privacy-tests.sh`, then the common slice gate. Confirm `make released-schema-fixtures` invokes the same verifier and `make verify` includes that target; obtain recovery/security review.
- [ ] Stage only the named files, commit `扩展 v10 v11 金丝雀夹具与只读恢复`, and `git push`.

## Task 9: Re-run final 500k/1M gates and close only the persistence slice

**Files**

- Modify `Packages/SpaceTraceKit/Sources/SpaceTracePersistenceBenchmark/main.swift`
- Modify `docs/engineering/sqlite-history-benchmark.md`
- Create `docs/engineering/sqlite-v11-historical-ledger.md`
- Create `docs/engineering/sqlite-v11-historical-ledger.zh-CN.md`
- Modify `docs/architecture/decisions/ADR-004-sqlite-persistence-and-retention.md`
- Modify `docs/architecture/decisions/ADR-006-immutable-observations-and-findings.md`
- Modify `docs/architecture/decisions/ADR-006-immutable-observations-and-findings.zh-CN.md`
- Modify `docs/engineering/implementation-status.md`
- Modify `docs/engineering/implementation-status.zh-CN.md`
- Modify `CHANGELOG.md`
- Modify `Scripts/check-historical-ledger-privacy.sh`
- Modify `Scripts/Tests/check-historical-ledger-privacy-tests.sh`

- [ ] Run final repository-backed workloads with `swift run --package-path Packages/SpaceTraceKit -c release SpaceTracePersistenceBenchmark --mode v11-repository --directory-samples 500000 --scenario matrix` and the same command with `1000000`. Use the exact Task-2 primary, high-frame-count, 100%-stable, 2%-churn, and v10→v11 overlap distributions. Record endpoint/finding write p95, pending-work/effective-Top10 p95, the separate legacy root-bounded seven-day Top-100 p95, retention and WAL-truncate time, peak RSS, dictionary/cardinality/churn counts, retained/removed rows, per-object `dbstat`, and complete-database main/WAL/SHM totals. Primary/overlap gates: `<250,000,000` bytes, `<150,000,000` peak RSS, 500-directory-sample write p95 `<=100 ms`, and both legacy and v11 query p95 `<=500 ms` on the documented current host; one query may not substitute for the other.
- [ ] Add matching English/Chinese evidence for schema, transaction state machine, ACK-loss, retention/privacy, recovery, benchmark distribution, sensitive columns, and exact non-claims. Mark ADR-004/006 as Proposed unless all separate adoption gates actually pass. Do not call v11 supersession, production scanner integration, UI, or release complete.
- [ ] Extend the cumulative privacy checker's self-tests for the final source/fixture set, then prove it still scans every committed file since the plan boundary plus current staged/unstaged/untracked files. Review binary fixtures by manifest and synthetic generator, not by dumping them into logs.
- [ ] Run `swift test --package-path Packages/SpaceTraceKit --filter SQLiteHistorical`, `swift test --package-path Packages/SpaceTraceKit -Xswiftc -strict-concurrency=complete`, `./Scripts/check-architecture.sh`, both final benchmark commands, `bash Scripts/verify-released-schema-fixtures.sh`, `bash Scripts/Tests/check-historical-ledger-privacy-tests.sh`, `./Scripts/check-historical-ledger-privacy.sh`, `git diff --cached --check`, and `make verify`. Obtain independent code, database/recovery, and requirements/privacy reviews; resolve every P1/P2.
- [ ] Commit code/tests/fixtures as `完成 SQLite v11 历史账本可靠性与性能验证`, push; then commit bilingual evidence/status as `完成 SQLite v11 双语证据与阶段收口`, and push.

## Release blockers after this plan

This plan intentionally leaves the product **NO-GO**. The next plans must still complete:

1. production scanner capture of stable directory identity, reuse guard, link ambiguity, explicit absence, complete direct-child coverage, and frozen attribution;
2. replacement of the legacy pipeline finalization with the paired v11 API, projector lifecycle scheduling/restart, and removal of the bypass;
3. an approved correction/replacement model and later schema migration if append-only supersession remains a requirement;
4. Overview/menu-bar finding presentation with exact logical/allocated/APFS uncertainty wording, accessibility, localization, and no delete/cleanup implication;
5. FR-014 user-confirmed redacted export; the FR-007 reviewed corpus gate was completed on 2026-08-13 with 64 known and 32 Unknown scenarios;
6. ADR-004/ADR-006 maintainer acceptance, production retention-scheduler wiring, checkpoint-busy recovery, and Application-Support backup/quarantine scrub qualification;
7. APFS/non-APFS stable identity, reuse, link ambiguity, remount, and external-volume real-device matrices plus a 30-day virtual retention/crash-before-checkpoint run;
8. reset/settings/database-size UI, presentation of typed History Off/baseline-unavailable states, the separate full-store Clear History workflow and five-second stop/delete qualification, signed sandbox restart/revocation/external-volume return, benchmark/privacy qualification on macOS 15.6 and the current stable macOS, 24-hour soak/energy evidence, packaging, and release review.

## Self-review checklist

- Sequence ownership: only frame commit marker assigns sequence; candidates cannot serialize as committed evidence.
- Atomicity: paired adapter writes two metrics and existing calibration state together; legacy production path is named, tested, and not misrepresented.
- Identity: v11 BLOB codecs preserve byte-distinct Unicode and embedded NUL without C-string truncation.
- Evidence: explicit absent endpoints and complete same-frame direct-parent proof are required; missing rows never become disappearance.
- Projection: only v1 deterministic output is persisted; work/checkpoint ownership is `work_id`, so no cross-wiring occurs.
- Correction honesty: v11 retraction is reachable and idempotent; the schema exposes no misleading supersession surface, and replacement/correction remains a release gate.
- Retention: active-ledger expiry is anchored to the earliest observation, shorter/off policy is supported, full dependent graphs expire, and app-controlled SQLite artifacts are logically scrubbed without making a forensic-deletion claim.
- Recovery: complete schema objects and logical ledger are validated; v10/v11 fixtures are populated and deterministic.
- Scale: the exact complete schema is measured before migration freeze and again after implementation; no unmeasured index or unique-path workload substitution is hidden.
- Delivery: every task has concrete files, RED/GREEN commands, independent review, scoped Chinese commit, and push.
