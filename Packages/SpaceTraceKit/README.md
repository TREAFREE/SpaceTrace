# SpaceTraceKit

`SpaceTraceKit` is the local Swift package that holds SpaceTrace's non-UI implementation. The macOS application target is intentionally kept as a thin composition root.

## Modules

| Module | Responsibility | Platform coupling |
| --- | --- | --- |
| `SpaceTraceDomain` | Validated storage quantities, observation identities, coverage, and deltas | None |
| `SpaceTraceApplication` | Dirty-region planning, calibration orchestration, mount-generation state machine, ports, and crash-consistency contracts | Foundation |
| `SpaceTraceFileSystem` | Per-device FSEvents identity/target resolution, callback bridge, conservative flag interpretation, semantic mapping, and a bounded metadata-only calibration scanner | CoreServices, Foundation, Darwin |
| `SpaceTracePersistence` | Actor-isolated raw SQLite prototype for cursor, dirty work, scope mount generations, staged directory aggregates, and revision-safe atomic publication | SQLite3 |
| `SpaceTracePlatform` | Read-only Disk Arbitration callback bridge with owned volume evidence, bounded buffering, and lifecycle-safe teardown | DiskArbitration, Dispatch |
| `SpaceTraceMonitoring` | Non-UI composition of volume signals, exact mount-scope resolution, generation activation/closure, and FSEvents supervision | Application, filesystem, and platform adapters |

The filesystem, platform, monitoring, application pipeline, and persistence modules are architecture-spike implementations for proposed ADR-003 and ADR-004. Their non-UI composition is implemented and tested, but it is not connected to a user-visible workflow while those decisions remain proposed.

The package test suite includes serialized per-device FSEvents tests. They create and remove only a UUID-named directory below the system temporary directory, fail closed unless that directory is on APFS and outside the user's home directory, and use a native flush boundary instead of timing sleeps. Durable replay requires both a persistent volume UUID and the current FSEvents journal UUID; otherwise the resolver permits only `sinceNow` monitoring.

The non-UI supervisor also owns post-start failure recovery. An unexpected termination first makes continuity loss durable, then re-resolves the approved mount evidence and starts a `sinceNow` stream under the same mount generation. Recovery uses bounded exponential backoff and a circuit breaker; unmount, generation replacement, and shutdown cancel the owned recovery task.

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
