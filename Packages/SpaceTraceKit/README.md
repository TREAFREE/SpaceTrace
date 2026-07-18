# SpaceTraceKit

`SpaceTraceKit` is the local Swift package that holds SpaceTrace's non-UI implementation. The macOS application target is intentionally kept as a thin composition root.

## Modules

| Module | Responsibility | Platform coupling |
| --- | --- | --- |
| `SpaceTraceDomain` | Validated storage quantities, observation identities, coverage, and deltas | None |
| `SpaceTraceApplication` | Dirty-region planning, calibration orchestration, ports, and crash-consistency contracts | Foundation |
| `SpaceTraceFileSystem` | FSEvents callback bridge, conservative flag interpretation, and application-semantic mapping | CoreServices |
| `SpaceTracePersistence` | Actor-isolated raw SQLite prototype for cursor, dirty work, and conditional finalization | SQLite3 |

The filesystem, application pipeline, and persistence modules are architecture-spike implementations for proposed ADR-003 and ADR-004. The pipeline is validated with an injected scanner; a production metadata enumerator and user-visible workflow are not connected yet.

## Verify

From the repository root:

```bash
swift test --package-path Packages/SpaceTraceKit
```

Or run every repository gate:

```bash
make verify
```
