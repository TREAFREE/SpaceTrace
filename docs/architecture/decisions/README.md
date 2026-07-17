# Architecture Decision Records

This directory records durable technical, data, permission, distribution, and security decisions for SpaceTrace. ADRs are authoritative only when their status is **Accepted**. Proposed ADRs describe the current recommendation and validation needed before implementation may treat them as settled.

| ADR | Decision | Status |
| --- | --- | --- |
| [ADR-001](ADR-001-native-macos-platform.md) | Native macOS modular monolith, macOS 15.6 minimum, and Apple Silicon-first baseline | Accepted; Intel support deferred |
| [ADR-002](ADR-002-read-only-optional-full-disk-access.md) | Read-only operation with optional Full Disk Access | Proposed |
| [ADR-003](ADR-003-fsevents-and-calibration-scans.md) | FSEvents invalidation journal plus calibration scans | Proposed |
| [ADR-004](ADR-004-sqlite-persistence-and-retention.md) | SQLite/GRDB adapter and 30-day bounded retention | Proposed; GRDB validation pending |
| [ADR-005](ADR-005-system-command-adapter.md) | Optional isolated read-only system-command adapter | Proposed |

## Status lifecycle

- **Proposed:** under review; implementation may spike but must not claim the decision is final.
- **Accepted:** approved source of truth and enforceable by implementation/release gates.
- **Deprecated:** retained for history but no longer recommended for new work.
- **Superseded:** replaced by another ADR, linked in both records.

## Required sections

Every ADR must include Status, Context, Decision, Options considered, Consequences, Validation plan, and Revisit triggers. A change that weakens privacy, expands mutation, changes default retention, adds network capability, changes database semantics, or changes the support matrix also requires the corresponding PRD/security review.
