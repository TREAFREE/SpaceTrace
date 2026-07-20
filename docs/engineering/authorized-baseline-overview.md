# Authorized Directory Baseline and Overview

Status: **Implemented application slice; FR-002 remains partially complete**

Last updated: 2026-07-20

Chinese companion translation: [authorized-baseline-overview.zh-CN.md](authorized-baseline-overview.zh-CN.md). This English document remains the engineering source of truth.

## Purpose and scope

This slice connects one restored, user-selected directory to a cancellable metadata baseline and renders only verifiable results in the overview. It implements the directory-root portion of FR-002. It does **not** yet implement startup data-volume capacity/available samples, multi-root aggregation, resumable baselines, thermal or power scheduling, or historical comparison points.

## Ownership and data flow

```text
Overview button
    -> BaselineScanViewModel (@MainActor presentation state)
    -> AuthorizedBaselineScanCoordinator (actor, task/state ownership)
    -> NativeAuthorizedBaselineScanContextProvider
         -> restored WatchedScope catalog
         -> active FSEvents stream generation
    -> EventJournalAuthorizedBaselineCalibrationRunner
         -> durable root requiresCalibration marker
         -> bounded metadata scanner
         -> SQLite staging
         -> revision-checked atomic publication
    -> published root aggregate or typed non-publication result
    -> overview
```

The context provider accepts only an already active `WatchedScopeID`. It returns the exact restored root and the stream ID of the active mount generation. The UI never constructs a capability or stream identity from path text.

The authorization coordinator cancels and awaits an in-flight baseline before replacing or revoking the permission capability. Application termination follows the same cancellation path before the security-scoped lease is released.

## Typed lifecycle

The application-owned state is one of:

- `idle`;
- `preparing`, while the authorized scope and active monitoring generation are resolved;
- `scanning`, while bounded metadata enumeration is active;
- `publishing`, after a complete report exists but before its revision-checked transaction commits;
- `completed`, containing a published complete root aggregate and scan report;
- `incomplete`, containing either partial-coverage evidence or a superseded-revision reason;
- `cancelled`, after the owned task has exited and staging has been discarded;
- `failed`, with a stable, privacy-safe failure code.

The overview uses an indeterminate progress indicator because the scanner does not know the final entry count before enumeration. It shows elapsed time and root counters without inventing a percentage. Entry and directory counts appear only after the scanner has produced them.

## Publication and coverage rules

1. Starting a baseline writes a cursor-free, scope-root `requiresCalibration` dirty region. An existing descendant region is conservatively coalesced under that root.
2. Scanner output is streamed to SQLite staging tables; no staged row is current truth.
3. A partial report is discarded and its dirty work remains. The UI may show real entry, directory, and gap counts, but it shows no staged byte total.
4. A complete report enters atomic publication. If a newer event changed the dirty revision, the run becomes `superseded`, staging is discarded, and the dirty work remains.
5. Only a successful publication is read back from `node_current` and shown as a byte result.
6. A published result identifies logical bytes and observable allocated bytes separately. The latter is not presented as unique APFS physical allocation or reclaimable space.
7. Cancellation discards staging and never relabels partial work as complete.

These rules preserve the architecture invariant that unknown is not zero.

## User-visible behavior

With an active directory grant, the overview offers **Start baseline scan**. During work it shows the current typed phase, elapsed time, root counters, any available scan counts, and a cancellation control.

A successful card shows:

- exact authorized root;
- complete coverage;
- logical and observable allocated size using binary units;
- descendant and visited-entry counts;
- publication time;
- a rescan action.

Partial coverage, revision supersession, cancellation, and failures have distinct messages and retry actions. None of those states display an unpublished byte total.

## Verification boundary

Deterministic package tests cover complete publication, partial non-publication, revision supersession, cancellation, typed progress order, context failures, and real SQLite read-back. Application tests cover the MainActor projection and command forwarding. Full repository verification builds Debug and Release app configurations and executes package and application unit suites.

Native security-scoped selection and mount lifecycle remain covered by their existing signed-sandbox and APFS-image protocols. This slice does not claim that the full FR-002 journey has passed on macOS 15.6; deployment-target compilation on a newer host is not runtime qualification.
