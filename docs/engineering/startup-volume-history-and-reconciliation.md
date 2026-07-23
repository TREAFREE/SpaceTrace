# Startup Volume History and Storage Reconciliation

Status: implemented and verified on the current development host

Date: 2026-07-24

Related requirements: FR-005, FR-006, FR-008

Related decision: ADR-004

Chinese companion translation:
[startup-volume-history-and-reconciliation.zh-CN.md](startup-volume-history-and-reconciliation.zh-CN.md).
This English document remains the architecture source of truth.

## Delivered product chain

The Overview now presents one evidence-bounded chain for each selected
24-hour, 7-day, or 30-day window:

```text
startup data-volume available-space loss
        |
        v
allocated-size net growth in comparable authorized roots
        |
        v
credited explanation (never greater than the volume loss)
        |
        v
unattributed remainder
```

This is a reconciliation, not physical block accounting. It answers “how much
of the observed loss is visible inside the authorized evidence?” It does not
claim that allocated directory bytes are unique APFS blocks, immediately
reclaimable bytes, Apple “System Data,” or process attribution.

## Measurement and lifecycle

`FoundationStartupVolumeCapacityProvider` reads the volume containing
SpaceTrace's Application Support directory. The application records one sample
immediately after operational composition and then once per hour while the
process remains alive. A completed authorized baseline writes its capacity
observation into the same SQLite transaction as the baseline roots.

An unavailable platform value is still recorded as an attempted observation
with nullable metrics. Unknown is never converted to zero. The “available for
important usage” API value is retained separately and is not substituted for
current available space.

The lifecycle task belongs to `SpaceTraceAppDelegate`, is cancelled on
termination, and calls an application-owned
`StartupVolumeCapacityRecorder`. The use case depends only on provider and
repository ports; AppKit, Foundation volume APIs, and SQLite remain adapters.

## Schema v9

Schema v9 adds:

- `startup_volume_capacity_sample`, with an SQLite `AUTOINCREMENT` sequence,
  UTC observation time, optional volume UUID and capacity fields, and a typed
  `lifecycle` or `baseline` source;
- `authorized_baseline_root.volume_uuid`, so attribution does not parse opaque
  stream IDs or infer identity from a mount path;
- a 30-day capacity-history retention rule;
- migration of v8 baseline capacity samples in stable commit order and
  conservative root-volume backfill from the authorized bookmark or latest
  mount-generation evidence.

The sequence is the durable observation order. Wall-clock time remains useful
for bucketing but cannot reorder commits when time repeats or moves backward.
A detected rollback marks the projection partial and suppresses endpoint
reconciliation for that window rather than comparing observations in a false
chronological order.
Golden fixtures now cover released schemas v6, v7, and v8.

## Reconciliation rules

The application query applies these rules before showing an explanation:

1. Volume endpoints must have available-space values and belong to the same
   known startup-volume UUID. A volume replacement breaks the comparison.
2. Only roots whose persisted volume UUID equals that startup-volume UUID are
   candidates. Known external-volume roots are excluded.
3. A root with unknown volume identity remains unknown and lowers coverage.
4. Nested candidates are reduced to topmost roots. Parent and child aggregates
   are never added together.
5. Each retained root must have two allocated-size observations. Signed
   endpoint deltas are added across the disjoint roots, then negative net
   growth is clamped to zero.
6. Credited explanation is
   `min(volume loss, positive allocated-size net growth)`.
7. Unattributed loss is `volume loss - credited explanation`.

If no directory is comparable, the directory growth, credited explanation,
and unattributed remainder are all unavailable. The UI does not report the
entire loss as unattributed because doing so would silently treat absent
authorized evidence as a complete observation.

## Coverage and presentation

Missing hourly or daily buckets are explicit unavailable points and split the
chart. A known volume identity change also splits the capacity line. Text,
symbols, point size, and accessibility labels communicate coverage without
depending on color alone.

The reconciliation card displays:

- “Disk space lost” from startup-volume available-space endpoints;
- “Explained by authorized directories” from the guarded allocated-size
  comparison;
- “Still unattributed” only when directory evidence is comparable.

The adjacent directory chart and Top 10 ranking keep their logical-size
semantics. The ranking is not summed and is not reused as the reconciliation
total.

The UI discloses that an unattributed remainder can include unauthorized or
unreadable locations, APFS snapshots/clones, system and application caches,
purgeable behavior, or evidence gaps. It is not direct proof of suspicious
files.

## Verification

- Application tests cover full reconciliation, volume-only unknown results,
  nested-root deduplication, external-volume exclusion, and identity changes.
- SQLite tests cover monotonic commit sequence under repeated/rollback wall
  time, atomic baseline/capacity publication, root UUID round-trip, v8-to-v9
  backfill, and capacity retention.
- MainActor/presentation tests cover volume-only loading and line breaks for
  gaps and identity replacement.
- Released-schema SHA-256 fixtures migrate v6, v7, and v8 to the current
  schema.
- `make verify` remains the repository-wide final gate.

## Remaining qualification

- The current-host evidence does not qualify real runtime behavior on macOS
  15.6; that minimum-reference run remains required.
- Long sleep or app termination naturally creates explicit sampling gaps.
- APFS physical uniqueness, snapshot enumeration, classification, move and
  deletion findings, menu-bar metrics, history reset, and release signing
  remain separate work.
- ADR-004 remains Proposed until its remaining minimum-OS, distribution, and
  maintainer-review gates are complete.
