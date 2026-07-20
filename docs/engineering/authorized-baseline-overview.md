# Authorized Directory Baseline and Overview

Status: **Implemented application slice; FR-002 remains partially complete**

Last updated: 2026-07-20

Chinese companion translation: [authorized-baseline-overview.zh-CN.md](authorized-baseline-overview.zh-CN.md). This English document remains the engineering source of truth.

## Purpose and scope

This slice connects restored, user-selected directories to a cancellable metadata baseline and renders only verifiable results in the overview. The committed record includes a startup-data-volume capacity sample and survives an application restart. The permission UI now projects every configured scope independently and sends all currently active scope IDs through the bounded multi-root request. FR-002 still does **not** implement true mid-scan continuation, thermal or power scheduling, or historical comparison points.

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
    -> startup data-volume capacity sample
    -> SQLite v6 authorized baseline snapshot transaction
         -> app/schema version
         -> volume total/current-available/important-usage estimate
         -> ordered root summaries
    -> new result, restored committed result, or typed non-publication result
    -> overview
```

The context provider accepts only an already active `WatchedScopeID`. It returns the exact restored root and the stream ID of the active mount generation. The UI never constructs a capability or stream identity from path text. Each newly added directory receives a path-independent persistent ID; reauthorization and replacement reuse that ID. Exact duplicate roots are rejected by the capability catalog. A request accepts 1–64 unique scope IDs and sorts them by stable ID before work begins.

The authorization coordinator cancels and awaits an in-flight baseline before replacing or revoking the permission capability. Application termination follows the same cancellation path before the security-scoped lease is released.

## Typed lifecycle

The application-owned state is one of:

- `idle`;
- `preparing`, while the authorized scope and active monitoring generation are resolved;
- `scanning`, while bounded metadata enumeration is active;
- `publishing`, after a complete report exists but before its revision-checked transaction commits;
- `completed`, containing a durable complete baseline snapshot; its origin says whether it was just scanned or restored after restart;
- `incomplete`, containing either partial-coverage evidence or a superseded-revision reason;
- `cancelled`, after the owned task has exited and staging has been discarded;
- `failed`, with a stable, privacy-safe failure code.

The overview uses an indeterminate progress indicator because the scanner does not know the final entry count before enumeration. It shows elapsed time and root counters without inventing a percentage. Entry and directory counts appear only after the scanner has produced them.

## Multi-root scheduling policy

- The coordinator actor owns one batch task and scans roots sequentially in stable scope-ID order. This deliberately avoids multiplying disk pressure with parallel recursive enumeration.
- Progress carries the current root context plus `completedRootCount`, `totalRootCount`, and unreadable-root evidence. Moving to the next root is the proof that the prior root published successfully.
- The complete baseline snapshot is written exactly once, after every requested root has complete coverage. A partial or superseded root stops the batch and commits no snapshot, even if earlier directory aggregates were safely published to `node_current`.
- Cancellation cancels and awaits the active root runner. The cancellation state records every requested scope and the count already completed, but no partial batch is relabeled as a committed baseline.
- The request cap of 64 roots, per-root scan budgets, and sequential execution create an explicit upper bound. This is a safety limit, not a recommendation that the UI should encourage 64 roots.

## Publication and coverage rules

1. Starting a baseline writes a cursor-free, scope-root `requiresCalibration` dirty region. An existing descendant region is conservatively coalesced under that root.
2. Scanner output is streamed to SQLite staging tables; no staged row is current truth.
3. A partial report is discarded and its dirty work remains. The UI may show real entry, directory, and gap counts, but it shows no staged byte total.
4. A complete report enters atomic publication. If a newer event changed the dirty revision, the run becomes `superseded`, staging is discarded, and the dirty work remains.
5. Only a successful directory publication is read back from `node_current`. The coordinator then samples the volume containing SpaceTrace's Application Support directory and writes the v6 baseline snapshot in its own transaction.
6. The UI enters `completed` only after that snapshot transaction succeeds. A crash or write failure between directory publication and snapshot commit cannot create a false durable baseline: restart restores the previous committed snapshot, or none.
7. A published result identifies logical bytes and observable allocated bytes separately. The latter is not presented as unique APFS physical allocation or reclaimable space.
8. Cancellation discards staging and never relabels partial work as complete.

These rules preserve the architecture invariant that unknown is not zero.

## Durable metadata and restart policy

Schema v6 adds `authorized_baseline_snapshot` and `authorized_baseline_root`. Each committed snapshot records its start/commit times, App version, schema version, complete coverage, volume observation time and optional capacity values. Roots are stored as the same ordered, unique-scope collection produced by the multi-root scheduler.

On startup, SQLite performs a bounded recovery transaction. Any `running` calibration row belongs to the dead process: its staging rows are deleted, it is marked failed, and its durable dirty work remains. SpaceTrace deliberately does not claim that arbitrary filesystem enumeration can resume from an in-memory midpoint. After authorization restoration, the coordinator loads only the latest committed baseline containing that scope and labels the UI result as restored.

The startup-data-volume provider queries the volume containing the Application Support directory rather than assuming an APFS mount path. `total`, immediately `available`, and `availableForImportantUsage` are distinct optional values. The important-usage value may include space macOS can make available and is not labeled as current free blocks. Unavailable API values remain unknown.

## User-visible behavior

With one or more active directory grants, the overview offers **Start baseline scan** for the complete active set. A temporarily unavailable or stale entry remains independently visible and does not hide healthy grants. During work the overview shows the current typed phase, elapsed time, root counters, any available scan counts, and a cancellation control.

A successful card shows:

- every exact authorized root as a separate result, without inventing an overlap-prone aggregate byte total;
- complete coverage;
- logical and observable allocated size using binary units;
- descendant and visited-entry counts;
- startup data-volume total and current available capacity;
- the separate macOS important-usage availability estimate;
- publication time;
- App/schema version and whether the card was restored from local committed state;
- a rescan action.

Partial coverage, revision supersession, cancellation, and failures have distinct messages and retry actions. None of those states display an unpublished byte total.

## Verification boundary

Deterministic package tests cover complete publication, partial non-publication, revision supersession, cancellation, typed progress order, context failures, capacity sampling, deterministic multi-root ordering, one-snapshot commit, later-root partial failure, later-root cancellation, request bounds, duplicate-root rejection, snapshot round-trip, restart restoration, interrupted-staging cleanup, and preservation of dirty work. Application tests cover the MainActor multi-scope projection, stable add/reauthorize/remove commands, mixed availability, mutation failure preservation, request limits, batch forwarding, and restoration. Full repository verification builds Debug and Release app configurations and executes package and application unit suites.

Native security-scoped selection and mount lifecycle remain covered by their existing signed-sandbox and APFS-image protocols. The multi-scope UI-test target compiles without signing, but its interactive run is not claimed because the current keychain contains no valid Apple code-signing identity. This slice does not claim that the full FR-002 journey has passed on macOS 15.6; deployment-target compilation on a newer host is not runtime qualification.
