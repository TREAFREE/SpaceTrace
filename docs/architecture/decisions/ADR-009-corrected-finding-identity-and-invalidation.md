# ADR-009: Versioned finding identity and corrected-finding invalidation

## Status

Proposed

Date: 2026-08-13

Chinese companion translation: [ADR-009-corrected-finding-identity-and-invalidation.zh-CN.md](ADR-009-corrected-finding-identity-and-invalidation.zh-CN.md). This English document is the engineering source of truth.

Related requirements: FR-004, FR-006, FR-013, NFR-003, NFR-006

Amends: [ADR-006](ADR-006-immutable-observations-and-findings.md) and [ADR-008](ADR-008-append-only-reconciliation-corrections.md) after acceptance

## Context

Schema v12 preserves a registered correcting projection in a separate
`historical_corrected_finding` table. Its database-owned IDs intentionally
occupy a namespace distinct from schema-v11 `historical_finding` IDs. The
existing `historical_finding_retraction` table can reference only an original
schema-v11 finding.

ADR-008 requires the current-effective view to hide an independently
invalidated finding attached to the terminal projection. That promise is not
implementable for a v12 corrected terminal finding: coercing its ID into the
v11 namespace can collide with an unrelated original, attaching the
retraction to the predecessor revives incorrect data, and silently dropping
the corrected finding loses the audit reason. Because v12 has a frozen golden
fixture and migration contract, its schema must not be rewritten in place.

## Decision

### 1. Versioned in-memory identities

Application read models use explicit sum types:

- projection identity is either `.original(HistoricalProjectionRecordID)` or
  `.correcting(HistoricalCorrectingProjectionRecordID)`;
- finding identity is either `.original(HistoricalFindingRecordID)` or
  `.corrected(HistoricalCorrectedFindingRecordID)`.

No integer offset, sign bit, hash, path, or display string may bridge the two
namespaces. Canonical ordering compares the source discriminator first and the
positive database ID second.

### 2. Schema-v13 corrected-finding retraction

Schema v13 appends `historical_corrected_finding_retraction`. One row freezes:

- a database-owned positive retraction sequence;
- one 16-byte request ID and versioned canonical request digest;
- one unique corrected-finding ID;
- the exact stored corrected draft SHA-256;
- the single released reason `evidence_invalidated`;
- commit time and the corrected projection's existing expiry boundary.

The target must belong to a complete checkpointed correcting projection. The
expected digest must equal the immutable target row. The retraction is
append-only, has at most one row per corrected finding, and cannot outlive its
target projection. Schema-v11 retractions remain byte-for-byte unchanged.

### 3. Authorization and idempotence

The public repository exposes read-only versioned finding/audit queries. A
package-only, non-`Codable` command is constructible only by the existing typed
integrity reconciliation authorizer after it reloads the exact audit record.
UI, classifier, cleanup, and arbitrary correction code cannot choose an ID or
digest. Retry outcomes remain newly committed, byte-identical already
committed, or immutable conflict.

### 4. Current-effective and audit behavior

The current-effective query resolves the terminal projection first, validates
its complete result, removes retracted findings only within that terminal
projection, reconstructs canonical order, and applies the caller limit last.
It never falls back to a predecessor merely because the terminal replacement
is empty or fully retracted.

The audit query returns the original projection, every correcting edge,
unchanged findings and digests, both retraction kinds, registered semantic
identity, and commit metadata in predecessor order. A comparison-sequence
limit remains an observation bound, not a correction-time snapshot.

### 5. Migration, retention, and release boundary

The v12→v13 migration is additive and invents no retraction. Retention and
History Off delete v13 retractions before corrected findings, then continue in
the already verified v12 dependency order. Recovery, released fixtures,
privacy checks, and the one-million-node size gate include v13 before Task 7
query integration can be considered complete.

## Consequences

- Corrected and original finding IDs cannot collide in UI or audit caches.
- Evidence discovered after a registered correction has an honest append-only
  invalidation target.
- v12 bytes and existing local databases remain readable and immutable.
- One additional migration and table are required before FR-004 can close.

## Validation

1. Prove colliding raw IDs remain distinct versioned values and sort stably.
2. Prove v12→v13 migration creates an empty table without changing any v12 row.
3. Prove authorization, ACK-loss retry, changed-field conflict, target/digest
   validation, rollback, expiry, retention, and History Off behavior.
4. Prove terminal corrected findings honor their own retractions and never
   revive predecessor findings.
5. Re-run strict concurrency, released fixtures, privacy, capacity, recovery,
   signed sandbox, macOS 15.6, and DMG gates.

