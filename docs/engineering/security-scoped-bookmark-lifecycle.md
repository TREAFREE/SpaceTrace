# Security-Scoped Bookmark and Application Lifecycle

Status: **Implemented architecture and minimal UI; full signed/oldest-OS qualification remains open**

Last verified: 2026-07-19

Chinese companion translation: [security-scoped-bookmark-lifecycle.zh-CN.md](security-scoped-bookmark-lifecycle.zh-CN.md). This English document remains the engineering source of truth.

## 1. Scope

This slice establishes the permission boundary between a user-selected directory and native monitoring:

```text
system selection URL
  -> read-only security-scoped bookmark acquisition
  -> SQLite schema v5 watched-scope record
  -> exact bookmark restoration and access lease
  -> WatchedScope catalog
  -> Disk Arbitration / FSEvents runtime
  -> process-level application lifecycle
```

The minimal UI now presents `NSOpenPanel` only after an explicit action and passes its original URL to the catalog. It does not select a default directory, request Full Disk Access, or make monitoring results user-visible. Converting the picker URL to a string before acquisition remains invalid because the string does not carry the security scope.

## 2. Ownership boundaries

| Owner | Responsibility | Must not do |
| --- | --- | --- |
| `SpaceTraceApplication` | Opaque bookmark record, persistence port, restoration report, catalog lifecycle protocol | Interpret bookmark bytes or call platform APIs |
| `SpaceTracePersistence` | Store the bookmark and expected identity in SQLite v5 | Log, export, decode, or broaden a grant |
| `SpaceTracePlatform` | Create/resolve native bookmarks, validate the exact resource, balance access leases, implement the catalog | Open UI or infer product policy |
| `SpaceTraceMonitoring` | Restore the catalog, own one long-lived runtime task, serialize grant mutation with runtime restart, cancel and release on shutdown | Bind monitoring to a window/view lifecycle |
| `SpaceTraceApp` | Build Application Support storage, present the system picker, project typed state on MainActor, and bridge `NSApplication` launch/termination | Decode bookmark data or own native monitoring tasks |

The catalog retains one access lease per active scope. Every successful `startAccessingSecurityScopedResource()` is balanced exactly once by `stopAccessingSecurityScopedResource()` during catalog replacement, runtime failure, or application shutdown.

## 3. Persisted record and identity rules

Schema v5 adds `watched_scope_bookmark`:

- stable `scope_id`;
- opaque bookmark BLOB, bounded to 1 MiB;
- exact normalized root captured at authorization time;
- required volume UUID;
- created/updated timestamps.

The mount path is intentionally **not** persisted as authorization. It is derived from `URLResourceKey.volumeURLKey` every time the bookmark resolves. `WatchedScope` construction then proves that the resolved root remains inside that mount path.

A restored grant is accepted only when all of the following are true:

1. bookmark resolution succeeds without UI and without mounting a volume;
2. the bookmark is not stale;
3. the resource is a directory and is not a symbolic link;
4. security-scoped access starts successfully in the sandboxed app;
5. the normalized resolved root exactly matches the authorized root;
6. the resolved volume UUID exactly matches the authorized volume UUID;
7. the root remains lexically beneath the freshly derived mount path.

Failure is scope-local and privacy-safe. Reports expose only scope IDs and stable codes; they never contain a path, native error payload, or bookmark bytes.

## 4. Recovery policy

| Failure | Automatic behavior | Required recovery |
| --- | --- | --- |
| Volume absent during launch | Keep the record pending; retry resolution when a later mount event reads the catalog | None if the same volume returns |
| Stale bookmark | Do not refresh or rewrite it | User selects the directory again |
| Root path changed | Reject the restored scope | User reviews and selects the intended directory again |
| Volume UUID changed | Reject the restored scope | User explicitly authorizes the replacement volume |
| Symlink/non-directory | Reject | User selects a real directory |
| Access denied/revoked | Do not start monitoring that scope; release any partial lease | User restores permission explicitly |
| Database/catalog failure | Fail application monitoring startup and release all leases | Repair/recovery workflow (future UI) |

Starting the application with configured bookmarks but no currently restorable scopes still starts Disk Arbitration observation. This is necessary for an external volume that was authorized previously but is not mounted at launch. Starting with no configured bookmarks remains idle and performs no native volume observation.

## 5. Application lifecycle

`NativeMonitoringApplicationLifecycle` is an actor and the only owner of the long-lived monitoring task:

1. restore the catalog;
2. remain idle when the catalog has no persisted records;
3. otherwise start exactly one `NativeVolumeMonitoringRuntime.run()` task;
4. expose a small non-UI state (`stopped`, `restoringPermissions`, `idleWithoutConfiguredScopes`, `monitoring`, `stopping`, `failed`);
5. on quit, cancel and await the runtime before releasing every security-scope lease.

The SwiftUI app uses `NSApplicationDelegateAdaptor`. `applicationShouldTerminate` returns `terminateLater`, performs asynchronous shutdown, then replies to AppKit. Closing a window does not stop monitoring.

User-driven replacement or removal is owned by `WatchedScopeAuthorizationCoordinator`: stop the runtime, persist the capability change, restore the catalog, and start the runtime again. If mutation fails, it attempts to restore monitoring from persisted truth. UI controls are disabled during a transition, and canceling `NSOpenPanel` performs no mutation.

## 6. Entitlements and distribution modes

The checked-in development application is currently sandboxed and declares:

```xml
com.apple.security.app-sandbox = true
com.apple.security.files.user-selected.read-only = true
com.apple.security.files.bookmarks.app-scope = true
```

It therefore composes the catalog with `.required`, which fails closed when a sandbox extension cannot start.

ADR-002 separately proposes a directly distributed, unsandboxed product for broader ordinary-user-readable coverage. That proposal is not accepted by this implementation. The platform adapter has an explicit `.bookmarkIdentityOnly` mode for tests and a possible future direct-distribution composition; it skips sandbox-extension activation but retains exact bookmark/root/volume validation. Changing the release entitlement set still requires ADR/security review and release qualification.

## 7. Verification

Deterministic tests cover:

- model bounds and privacy-safe restoration reports;
- valid/stale mixed restoration;
- retry after an unavailable external volume returns;
- no automatic retry or refresh for stale bookmarks;
- acquisition persistence and exactly-once lease release;
- a real native bookmark round-trip without UI in identity-only mode;
- SQLite v4-to-v5 migration, replacement, round-trip, and removal;
- lifecycle idle/start/duplicate-start/failure/cancellation/shutdown behavior;
- persisted-first grant removal, mutation rollback, runtime restart, and transition serialization;
- MainActor view-model projection for selection, picker cancellation, stale reauthorization, explicit removal, and absent-volume refresh;
- package complete strict-concurrency diagnostics and Xcode Debug/Release composition builds through `make verify`.

The checked-in [qualification protocol](user-selected-directory-qualification.md) covers signed system selection, relaunch, explicit grant removal, stale/identity evidence, external-volume absence/return/replacement, app quit, and the macOS 15.6 runtime gate. Current-host ad-hoc smoke evidence cannot close the Apple-identity signing or macOS 15.6 gates.
