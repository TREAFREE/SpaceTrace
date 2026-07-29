# SpaceTraceKit

`SpaceTraceKit` is the local Swift package that holds SpaceTrace's non-UI implementation. The macOS application target is intentionally kept as a thin composition root.

## Modules

| Module | Responsibility | Platform coupling |
| --- | --- | --- |
| `SpaceTraceDomain` | Validated storage quantities, observation identities, coverage, and deltas | None |
| `SpaceTraceApplication` | Dirty-region planning, cancellable and schedulable authorized-baseline state, background capacity/retention lifecycle, qualified 24-hour status, coverage-aware directory/volume history and reconciliation use cases, calibration orchestration, mount/event lifecycle state machines, opaque watched-scope bookmark contracts, ports, and crash-consistency contracts | Foundation |
| `SpaceTraceFileSystem` | Per-device FSEvents identity/target resolution, callback bridge, conservative flag interpretation, semantic mapping, and a bounded metadata-only calibration scanner | CoreServices, Foundation, Darwin |
| `SpaceTracePersistence` | Actor-isolated raw SQLite prototype for cursor, dirty work, scope mount generations, security-scoped bookmark records, staged/current directory aggregates, bounded directory and startup-volume history, root-scoped growth queries, revision-safe atomic publication, typed storage failures, and retention | SQLite3 |
| `SpaceTracePlatform` | Read-only Disk Arbitration callback bridge, exact security-scoped bookmark acquisition/restoration and balanced access leases, plus public power/thermal/sleep signal adaptation | AppKit, Foundation, DiskArbitration, IOKit |
| `SpaceTraceMonitoring` | Non-UI composition of volume signals, exact mount-scope resolution, generation activation/closure, FSEvents supervision, and process-lifetime task ownership | Application, filesystem, and platform adapters |

The filesystem, platform, monitoring, application pipeline, and persistence modules are architecture-spike implementations for proposed ADR-003 and ADR-004. Their non-UI composition is implemented and tested, the process lifecycle restores persisted user grants before starting monitoring, and the checked-in app now exercises bounded permission, baseline, and directory-history slices. These user-facing slices do not accept either ADR or make the product Beta/release-qualified; the remaining evidence is tracked in the implementation-status document.

The package test suite includes serialized per-device FSEvents tests. They create and remove only a UUID-named directory below the system temporary directory, fail closed unless that directory is on APFS and outside the user's home directory, and use a native flush boundary instead of timing sleeps. Durable replay requires both a persistent volume UUID and the current FSEvents journal UUID; otherwise the resolver permits only `sinceNow` monitoring.

The non-UI supervisor also owns post-start failure recovery. An unexpected termination first makes continuity loss durable, then re-resolves the approved mount evidence and starts a `sinceNow` stream under the same mount generation. Recovery uses bounded exponential backoff and a circuit breaker; unmount, generation replacement, and shutdown cancel the owned recovery task. The supervisor publishes a bounded application-owned lifecycle stream (`inactive`, `active`, `recovering`, or `failed`) so a future health UI can observe transitions without importing CoreServices or polling adapter internals.

The exact claim boundary for daemon-generated `UserDropped`, `KernelDropped`, and event-ID wrap is documented in the [FSEvents continuity-loss qualification protocol](../../docs/engineering/fsevents-continuity-qualification.md) and its [Chinese translation](../../docs/engineering/fsevents-continuity-qualification.zh-CN.md).

The bookmark/catalog/application ownership contract is documented in [Security-Scoped Bookmark and Application Lifecycle](../../docs/engineering/security-scoped-bookmark-lifecycle.md) and its [Chinese translation](../../docs/engineering/security-scoped-bookmark-lifecycle.zh-CN.md).

The authorized directory baseline, typed progress, cancellation, atomic-publication, and overview truth contract are documented in [Authorized Directory Baseline and Overview](../../docs/engineering/authorized-baseline-overview.md) and its [Chinese translation](../../docs/engineering/authorized-baseline-overview.zh-CN.md).

The scope-bounded history read port, explicit-gap timeline, growth ranking, and Overview presentation contract are documented in [Directory History Application Layer and Overview](../../docs/engineering/directory-history-overview.md) and its [Chinese translation](../../docs/engineering/directory-history-overview.zh-CN.md).

The monotonic startup-volume sampling, schema-v10 sleep/wake-boundary
migration, conservative allocated-size reconciliation, and Overview truth
contract are documented in
[Startup Volume History and Storage Reconciliation](../../docs/engineering/startup-volume-history-and-reconciliation.md)
and its [Chinese translation](../../docs/engineering/startup-volume-history-and-reconciliation.zh-CN.md).

The power, thermal, and sleep-aware baseline policy is documented in [Scan Scheduling Lifecycle](../../docs/engineering/scan-scheduling-lifecycle.md) and its [Chinese translation](../../docs/engineering/scan-scheduling-lifecycle.zh-CN.md).

The startup/wake/time-change sampling lifecycle, automatic retention
scheduling, 24-hour truth contract, menu-bar projection, and long-duration
qualification boundary are documented in
[Background Storage Sampling Lifecycle and Menu Bar](../../docs/engineering/background-storage-sampling-lifecycle.md)
and its [Chinese translation](../../docs/engineering/background-storage-sampling-lifecycle.zh-CN.md).

The GRDB-versus-raw-SQLite decision, exact-version build evidence, failure tests, and remaining recovery/retention gates are documented in [SQLite Adapter Evidence Review](../../docs/engineering/sqlite-adapter-evidence-review.md) and its [Chinese translation](../../docs/engineering/sqlite-adapter-evidence-review.zh-CN.md).

An opt-in qualification test creates two 64 MiB APFS images with the same volume name, mounts only at a UUID-named path below `/tmp`, performs normal detach/remount/replacement, verifies distinct mount generations and restarted FSEvents delivery, then removes the images. It is intentionally excluded from normal `make verify` runs:

```bash
make package-apfs-image-qualification
```

## Verify

From the repository root:

```bash
swift test --package-path Packages/SpaceTraceKit
```

Or run every repository gate:

```bash
make verify
```

The deterministic background lifecycle qualification can also be run directly:

```bash
make package-background-lifecycle-qualification
```
