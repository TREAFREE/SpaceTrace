# SpaceTraceKit

`SpaceTraceKit` is the local Swift package that holds SpaceTrace's non-UI implementation. The macOS application target is intentionally kept as a thin composition root.

## Modules

| Module | Responsibility | Platform coupling |
| --- | --- | --- |
| `SpaceTraceDomain` | Validated storage quantities, observation identities, coverage, and deltas | None |
| `SpaceTraceApplication` | Application-owned ports and crash-consistency contracts | None |
| `SpaceTraceFileSystem` | FSEvents callback bridge and conservative flag interpretation | CoreServices |
| `SpaceTracePersistence` | Actor-isolated raw SQLite prototype for the event journal | SQLite3 |

The filesystem and persistence modules are architecture-spike implementations for proposed ADR-003 and ADR-004. They are not yet accepted production decisions and are not connected to a user-visible workflow.

## Verify

From the repository root:

```bash
swift test --package-path Packages/SpaceTraceKit
```

Or run every repository gate:

```bash
make verify
```
