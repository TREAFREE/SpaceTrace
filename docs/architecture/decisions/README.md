# Architecture Decision Records

This directory records durable technical, data, permission, distribution, and security decisions for SpaceTrace. ADRs are authoritative only when their status is **Accepted**. Proposed ADRs describe the current recommendation and validation needed before implementation may treat them as settled.

| ADR | Decision | Status |
| --- | --- | --- |
| [ADR-001](ADR-001-native-macos-platform.md) | Native macOS modular monolith, macOS 15.6 minimum, and Apple Silicon-first baseline | Accepted; Intel support deferred |
| [ADR-002](ADR-002-read-only-optional-full-disk-access.md) | Read-only operation with optional Full Disk Access | Proposed |
| [ADR-003](ADR-003-fsevents-and-calibration-scans.md) | FSEvents invalidation journal plus calibration scans | Proposed |
| [ADR-004](ADR-004-sqlite-persistence-and-retention.md) | SQLite adapter and 30-day bounded retention | Proposed; raw adapter retained; recovery, schema-v10 sleep-aware directory/volume history, reconciliation, and current-host benchmark implemented; oldest-OS gate pending |
| [ADR-005](ADR-005-system-command-adapter.md) | Optional isolated read-only system-command adapter | Proposed |
| [ADR-006](ADR-006-immutable-observations-and-findings.md) | Immutable observation endpoints, explicit absence, proven moves, exclusive ranking, and append-only finding projection | Proposed; pure contracts, schema-v11, production disappearance/APFS move integration, and bounded Overview implemented; adoption, manual UI qualification, and release gates pending |
| [ADR-007](ADR-007-user-initiated-diagnostic-export.md) | User-initiated, previewed diagnostic export with default redaction and a narrow save capability | Accepted; deterministic and cancellation tests passed; signed-sandbox/manual accessibility/DMG qualification pending |
| [ADR-008](ADR-008-append-only-reconciliation-corrections.md) | Append-only provisional-history revisions and registered same-evidence correcting projections | Proposed; schema-v12 implementation, migration, benchmark, UI, and adoption gates pending |
| [ADR-009](ADR-009-corrected-finding-identity-and-invalidation.md) | Versioned original/corrected identities and append-only corrected-finding invalidation | Proposed; schema-v13 migration, query, retention, UI, and adoption gates pending |

## Status lifecycle

- **Proposed:** under review; implementation may spike but must not claim the decision is final.
- **Accepted:** approved source of truth and enforceable by implementation/release gates.
- **Deprecated:** retained for history but no longer recommended for new work.
- **Superseded:** replaced by another ADR, linked in both records.

## Required sections

Every ADR must include Status, Context, Decision, Options considered, Consequences, Validation plan, and Revisit triggers. A change that weakens privacy, expands mutation, changes default retention, adds network capability, changes database semantics, or changes the support matrix also requires the corresponding PRD/security review.
