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
2. Maintain a stream per observed volume, preferring per-device persistence. Bind every durable cursor to both the persistent filesystem volume UUID and the volume-local FSEvents journal UUID; never persist the ephemeral `dev_t`. Track each scope's active mount generation separately from its event-journal generation. If a mounted volume has no usable journal UUID, use an absolute-path host live stream with a mount-generation-scoped, non-replayable identity.
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
- A volume UUID or FSEvents journal UUID mismatch invalidates prior event continuity.
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

### Validation evidence recorded on 2026-07-18

- A public-API resolver obtains the persistent volume UUID, current `dev_t`, volume-relative paths, and FSEvents journal UUID without invoking commands or broadening the selected scope.
- Durable stream IDs are deterministically derived from the volume UUID and journal UUID. Changing either identity produces a different stream generation.
- Missing persistent identity permits only `sinceNow` monitoring; configuration rejects replay from a stored cursor.
- A guarded disposable APFS integration suite uses `FSEventStreamCreateRelativeToDevice` and covers live delivery, cancellation cleanup, stop/restart, historical replay through `HistoryDone`, and real callback-buffer overflow.
- The four-test native suite passed 100 consecutive runs after its asynchronous overflow assertion was hardened.
- A read-only Disk Arbitration adapter copies appeared, disappeared, and mount-path-change callbacks into a bounded single-consumer stream; callback loss becomes an explicit continuity-loss marker.
- The application mount state machine and SQLite schema v4 persist one active mount generation per scope, deduplicate repeated callbacks, conservatively close active rows on app restart, open a new generation after unmount, keep missing stable identity unknown, detect a different volume UUID reusing the same mount path, and conditionally reject late unmount callbacks for an older generation.
- A non-UI composition runtime maps Disk Arbitration callbacks to application signals, matches the exact configured volume mount root, resolves a missing callback UUID through only the approved scope before activation, transactionally activates/closes generations, and owns one restartable FSEvents consumer per active scope. Callback overflow closes all correlated generations before recreating the Disk Arbitration session.
- An opt-in controlled fixture created two 64 MiB APFS images with the same display name and proved normal detach, same-volume remount, different-UUID replacement at the same mount point, distinct generations/stream IDs, and live FSEvents delivery on both volumes. New images without a journal UUID exercised the host-live fallback instead of inventing durable replay continuity.
- A protocol-backed deterministic client and fixed resolver inject both native creation and start rejection. When persistent replay is rejected, the supervisor atomically invalidates the stored checkpoint with scope-level calibration work before attempting exactly one `sinceNow` stream. A failed live recovery is never published as active and remains eligible for the non-UI runtime's bounded retry.
- Post-start stream termination now enters an actor-owned recovery lifecycle: continuity loss becomes durable before reopening, current mount evidence is re-resolved, a known volume UUID cannot degrade to unknown or change identity, and the replacement stream starts at `sinceNow`. Deterministic tests cover successful recovery, start-failure exhaustion, repeated-terminal exhaustion, exponential-backoff cancellation on unmount, and recovery-policy validation. Recovery attempts reset only after a processed observation or a configured stable interval.
- The application layer now owns a typed `inactive`/`active`/`recovering`/`failed` read model. The native supervisor publishes a bounded newest-state stream, including current-state replay for new observers, successful recovery, circuit-breaker failure, and generation-bound stop cleanup.
- An exhaustive model test executes all 2,401 four-signal sequences formed from two stable volume identities, three runtime disk identities, unmounts, and callback continuity loss. Repository activity, coordinator bindings, restart uniqueness, and conditional stop ownership remain consistent for every sequence.
- `UserDropped`, `KernelDropped`, event-ID wrap, and application callback overflow now have parameterized adapter-to-SQLite-to-calibration evidence. The separate [continuity-loss qualification protocol](../../engineering/fsevents-continuity-qualification.md) records why injected semantics cannot be presented as a genuine daemon trigger.

ADR-003 remains **Proposed**. Genuine daemon drop/wrap conditions, user-selected bookmark composition, and oldest-supported-OS qualification are still open validation items.

## Revisit triggers

- Measurements show FSEvents churn causes repeated scope-level scans under normal workloads.
- Apple deprecates or materially changes FSEvents behavior on the supported minimum OS.
- External/network volumes become a P0 requirement.
- Product requirements demand verifiable process-level provenance; this would require a separate product/security decision, not an extension of this ADR.
- A background helper becomes necessary to meet an accepted freshness SLO.
- Calibration energy use exceeds the budget after optimization.
