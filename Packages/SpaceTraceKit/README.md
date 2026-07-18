# SpaceTraceKit

`SpaceTraceKit` is the local Swift package that holds SpaceTrace's non-UI implementation. The macOS application target is intentionally kept as a thin composition root.

## Modules

| Module | Responsibility | Platform coupling |
| --- | --- | --- |
| `SpaceTraceDomain` | Validated storage quantities, observation identities, coverage, and deltas | None |
| `SpaceTraceApplication` | Dirty-region planning, calibration orchestration, ports, and crash-consistency contracts | Foundation |
| `SpaceTraceFileSystem` | FSEvents callback bridge, conservative flag interpretation, semantic mapping, and a bounded metadata-only calibration scanner | CoreServices, Foundation, Darwin |
| `SpaceTracePersistence` | Actor-isolated raw SQLite prototype for cursor, dirty work, staged directory aggregates, and revision-safe atomic publication | SQLite3 |

The filesystem, application pipeline, and persistence modules are architecture-spike implementations for proposed ADR-003 and ADR-004. A production metadata adapter and schema-v3 staging path are implemented and tested, but they are not connected to a user-visible workflow while those decisions remain proposed.

## Verify

From the repository root:

```bash
swift test --package-path Packages/SpaceTraceKit
```

Or run every repository gate:

```bash
make verify
```
