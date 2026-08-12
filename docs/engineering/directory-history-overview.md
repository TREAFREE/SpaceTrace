# Directory History Application Layer and Overview

Status: implemented and verified on the current development host

Date: 2026-07-24

Related requirements: FR-005, FR-006, FR-008, FR-016

Related decision: ADR-004

## Delivered slice

SpaceTrace now projects schema-v8 directory history through an
application-owned read port into the main Overview. The UI supports 24-hour,
7-day, and 30-day windows, UTC-ordered hourly/daily buckets, explicit evidence
gaps, per-root logical-size series, and the ten largest positive logical-size
changes available in the selected window.

This slice deliberately does not claim full FR-005/FR-006 completion. Startup-
volume history, immutable schema-v11 persistence, production complete-scan
paired finalization, and finding projection have since been implemented as
separate slices, but Overview/menu-bar finding presentation remains open.

## Dependency and privacy boundary

```text
Overview SwiftUI
      |
      v
DirectoryHistoryViewModel (MainActor)
      |
      v
DirectoryHistoryOverviewLoading
      |
      v
DirectoryHistoryOverviewQuery (Application)
      |
      v
DirectoryHistoryRepository (Application-owned port)
      |
      v
SQLiteEventJournalRepository (Persistence adapter)
```

SwiftUI does not import SQLite models or issue SQL. The persistence adapter
must bind both the active `streamID` and an exact authorized/published root
when ranking growth. Root matching uses equality and prefix comparison rather
than SQL `LIKE`, so `%` and `_` in valid filenames cannot broaden the query.
The application query rejects a returned path outside the requested root.

Revoking a permission does not delete retained history. The ordinary
operational query intersects published contexts with the scopes that are still
configured, so an explicitly removed root disappears from the Overview without
being prematurely deleted from retention. A temporarily unavailable configured
scope keeps its identity. The query cannot accidentally include another or
formerly selected root merely because it shared a volume stream.

## Evidence semantics

- Each watched root remains its own chart series. Multiple roots are not
  summed because overlapping selections could double-count the same bytes.
- Missing buckets are materialized as `unavailable` points and split line
  segments. The chart never interpolates across a gap or converts it to zero.
- A point is `complete` only when its persisted calibration coverage is
  complete and both logical and allocated metrics exist.
- Any missing or partial bucket makes the selected series/window partial.
  A window with no measured point is unavailable.
- A growth source is downgraded to partial whenever its surrounding timeline
  window is partial, even if its stored endpoint rows were complete.
- Ranking contains positive logical deltas only, with stable delta/path/scope
  ordering. Rows are never summed in the UI because parent and child directory
  aggregates may describe overlapping changes.
- Exact byte text uses binary units. Logical size is not described as unique
  APFS allocation, reclaimable space, or Apple “System Data.”

## Presentation states

The MainActor view model exposes only four durable presentation phases:

1. waiting for operational composition/first query;
2. loading a local query;
3. loaded, including volume-only and honest no-directory-history/no-growth results;
4. failed with a generic retry action and no database/path diagnostics.

Window changes are generation-checked so a slower older query cannot replace a
newer selection. Refresh is explicit. A published baseline context remains
available while a new scan starts, so the last committed history does not
disappear in favor of transient staging.

The UI uses standard SwiftUI controls and Charts, semantic colors, textual and
symbol coverage labels, selectable local paths, keyboard-accessible buttons,
VoiceOver labels, and accessibility identifiers. Larger points indicate
partial observations without relying on color alone.

## Verification

- Application query tests cover complete independent series, explicit gaps,
  unavailable history, request bounds, deterministic ordering, and
  cross-scope result rejection.
- SQLite tests prove root-bounded ranking excludes a larger positive change
  outside the requested root while retaining hourly/daily behavior.
- MainActor tests cover deterministic loading, window changes, context
  removal, failure/cancellation recovery, restored baseline context projection,
  and chart-segment breaks at unavailable buckets.
- The controlled current-host UI scenario passed and proves that authorization
  alone cannot produce a loaded history state. It uses a deterministic DEBUG
  fixture and does not replace the real Powerbox/bookmark/restart cases in the
  signed sandbox qualification matrix.
- `make verify` is the required final repository gate for this slice.

## Remaining work

1. Keep the completed startup-volume comparison aligned with this directory
   query contract; see [Startup Volume History and Storage Reconciliation](startup-volume-history-and-reconciliation.md).
2. Read the already-frozen schema-v11 classification/finding projection into
   this Overview without recomputing historical decisions.
3. Add explicit-absence reconciliation and qualify APFS stable identity before
   exposing move/disappearance; a missing row must never become disappearance
   evidence. See [Immutable Historical Findings](immutable-historical-findings.md).
4. Extend the already-qualified 24-hour menu-bar state with v11 finding and
   coverage status without turning incomplete evidence into a headline delta.
5. Add user-confirmed history reset and retention/storage-size settings.
6. Repeat UI, performance, and accessibility qualification on macOS 15.6
   before ADR-004 acceptance or Beta claims.
