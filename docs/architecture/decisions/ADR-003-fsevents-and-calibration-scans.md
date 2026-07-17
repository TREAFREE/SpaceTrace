# ADR-003: FSEvents invalidation journal plus calibration scans

## Status

Proposed

Date: 2026-07-18

## Context

SpaceTrace must detect storage changes over time without repeatedly crawling the entire filesystem. FSEvents is the public macOS mechanism for receiving persistent directory-tree change notifications. Its events can be coalesced, dropped, wrapped, reset with volume history, and delivered at directory rather than exact semantic granularity. They contain no byte counts and no reliable process identity.

Treating event paths as an audit log would create false precision. Repeated full scans would be simpler but would impose unacceptable energy and I/O cost. A correct design needs both mechanisms: events to invalidate cached regions and scans to measure current metadata.

Crash consistency creates a second problem. If the application advances an event cursor before durable scan work exists, changes can be lost after a crash. If it never checkpoints, restarts replay excessive work. Changes may also occur while a region is being scanned.

## Decision

1. FSEvents is an **invalidation journal**, never the source of storage-byte facts or process attribution.
2. Maintain a stream per observed volume, preferring per-device persistence and binding all cursors to a stable volume UUID plus a mount/stream generation.
3. Start monitoring before baseline/calibration enumeration so concurrent changes become dirty work.
4. In one SQLite transaction, persist/coalesce dirty regions before advancing the corresponding durable cursor.
5. Persist `FSEventStreamEventId` as the full `UInt64` value encoded in an eight-byte big-endian blob.
6. Lease each dirty region with its current maximum event ID. On scan finalization, clear it only if no newer event was persisted during the scan.
7. Use bounded, cancellable metadata scans to reconcile dirty regions. Scan output is staged and becomes visible only through atomic finalization with a coverage report.
8. On `MustScanSubDirs`, recursively scan the indicated region. On dropped events, ID wrap/reset, volume UUID mismatch, ambiguous root change, callback-bridge overflow, or start failure, mark cached state stale and schedule the narrowest safe calibration.
9. Coalesce dirty descendants under a dirty ancestor and collapse excessive queues to a scope-level calibration. Precision is sacrificed before correctness.
10. Never call APIs that purge FSEvents history.

## Options considered

| Option | Benefits | Costs / failure modes | Assessment |
| --- | --- | --- | --- |
| FSEvents + calibrated scans | Efficient steady state; explicit recovery; public API | Most complex state machine; needs durable queue and coverage model | Selected |
| FSEvents events treated as exact changes | Low scanning cost | No byte values/process IDs; coalescing and loss make results wrong | Rejected |
| Periodic full scan only | Simple correctness model | High I/O, battery use, slow freshness, poor laptop behavior | Rejected as primary; retained as recovery |
| Endpoint Security or audit stream | Potential process context | Entitlements/review/security burden; not needed for path trends; changes product promise | Rejected |
| Spotlight metadata as primary source | Fast queries and indexing | Index may lag, omit scopes, or be disabled; not a complete accounting source | Rejected as primary |
| Per-host stream only | Simpler root-volume code | Persistent IDs may conflict as volumes move between hosts | Rejected for durable multi-volume design |

## Consequences

### Positive

- Idle cost is proportional to changed regions rather than whole-disk size.
- Event loss becomes an explicit degraded state with a deterministic recovery path.
- Crash recovery can prove that no advanced cursor lacks durable reconciliation work.
- The model extends to multiple volumes without applying one volume's history to another.

### Negative and accepted trade-offs

- Scan results are eventually consistent and can lag during heavy churn or power throttling.
- The cursor/dirty/finalization protocol requires fault-injection and state-machine tests.
- A broad event or lost journal may still require an expensive calibration.
- Event timestamps cannot be inferred from IDs; wall-clock observation time is stored separately.

### Invariants

- `durable cursor ⇒ durable dirty coverage` for every event up to that cursor.
- A scan cannot clear a dirty row newer than its leased high-water mark.
- An incomplete scan cannot mark unseen descendants deleted.
- A volume UUID/generation mismatch invalidates prior event continuity.
- Findings use comparable scan observations; event arrival alone never creates a byte delta.

## Validation plan

Create a deterministic fake `EventStreamClient` and a real APFS integration suite covering:

1. create/modify/rename/delete storms with coalesced ancestors;
2. process termination at every transaction boundary around dirty rows and cursor update;
3. a new event arriving while the same region is staged/finalized;
4. callback bridge overflow;
5. injected `MustScanSubDirs`, dropped-event, ID-wrap, root-change, mount, and unmount flags;
6. volume replacement using the same mount name but a different UUID;
7. stream start failure and history reset;
8. monitoring started before a slow baseline while the tree mutates;
9. queue collapse thresholds and budget cancellation;
10. assertions that no finding names a process from FSEvents evidence.

Release gates require property-based event/scan/crash sequences to preserve the listed invariants.

## Revisit triggers

- Measurements show FSEvents churn causes repeated scope-level scans under normal workloads.
- Apple deprecates or materially changes FSEvents behavior on the supported minimum OS.
- External/network volumes become a P0 requirement.
- Product requirements demand verifiable process-level provenance; this would require a separate product/security decision, not an extension of this ADR.
- A background helper becomes necessary to meet an accepted freshness SLO.
- Calibration energy use exceeds the budget after optimization.
