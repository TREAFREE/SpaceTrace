# FSEvents Continuity-Loss Qualification

| Field | Value |
| --- | --- |
| Status | Accepted engineering protocol |
| Last updated | 2026-07-18 |
| Scope | `UserDropped`, `KernelDropped`, event-ID wrap, callback overflow, and post-start termination |
| Safety boundary | Public APIs, disposable fixtures, no privileged daemon manipulation |

## 1. Purpose

This protocol separates claims that SpaceTrace can verify deterministically from behavior that only macOS can produce under genuine FSEvents daemon conditions. A synthetic flag test proves application semantics; it does not prove that a specific OS build will emit the flag under pressure.

Apple's public SDK describes `UserDropped` and `KernelDropped` as diagnostic companions to `MustScanSubDirs`, and requires a recursive rescan when continuity is lost. It describes `EventIdsWrapped` as invalidating previously issued event IDs. The public SDK does not expose a supported API for forcing any of these daemon conditions.

## 2. Qualification matrix

| Condition | Automated evidence | Genuine daemon qualification | Current claim |
| --- | --- | --- | --- |
| Callback bridge overflow | Native APFS stream with a one-element application buffer | Not applicable; this is SpaceTrace-owned pressure | Qualified |
| Post-start stream termination | Injected controlling client, durable recovery work, bounded retry, cancellation, and observable lifecycle states | Native unexpected termination remains a lab scenario | Application lifecycle qualified |
| `UserDropped` | Flag decoding plus end-to-end dirty-region persistence and calibration | Only when naturally observed on a disposable APFS image | Semantics qualified; daemon trigger unqualified |
| `KernelDropped` | Flag decoding plus end-to-end dirty-region persistence and calibration | Only when naturally observed on a disposable APFS image | Semantics qualified; daemon trigger unqualified |
| `EventIdsWrapped` | Cursor suppression, atomic checkpoint invalidation, and calibration | No safe deterministic trigger for the 64-bit daemon counter | Semantics qualified; daemon trigger unqualified |
| Mount callback continuity loss | Exhaustive four-signal model sequences and native Disk Arbitration overflow recovery | Controlled APFS detach/remount/replacement test | Qualified on the development host |

## 3. Automated gates

The regular test suite must prove all of the following:

1. Native flags are copied into Sendable observations without exposing an unsafe cursor.
2. Every continuity-loss reason becomes cursor-free, durable root calibration work.
3. Event-ID wrap atomically invalidates the stored checkpoint.
4. Calibration can resolve the durable work only after a complete scan.
5. Unexpected stream termination publishes `active → recovering → active` or `active → recovering → failed`.
6. Unmount and generation replacement cancel or close the state that they own.
7. Every four-signal sequence over two volume identities and three runtime disk identities preserves repository, coordinator, and supervisor ownership invariants.

Run the regular evidence with:

```sh
swift test --package-path Packages/SpaceTraceKit
```

Run the destructive-environment APFS qualification only on a development machine with no production path mounted at the fixture location:

```sh
SPACETRACE_RUN_APFS_IMAGE_TESTS=1 swift test \
  --package-path Packages/SpaceTraceKit \
  --filter APFSDiskImageLifecycleIntegrationTests
```

## 4. Genuine daemon evidence protocol

A genuine daemon result is accepted only when all evidence comes from a disposable APFS disk image and the raw native callback contains the relevant public flag. The record must include:

- macOS build, hardware architecture, filesystem type, and test build commit;
- raw flag word and decoded reasons;
- watched scope and disposable image identity, with user paths redacted;
- checkpoint before and after the callback;
- durable dirty region before calibration;
- calibration coverage and final lifecycle state;
- whether the observation is repeatable on a second clean image.

Absence of a daemon-generated flag is an inconclusive result, not a passing result. Event pressure may be used only inside the disposable image and must remain bounded by an explicit file-count and byte budget.

## 5. Prohibited qualification techniques

Do not:

- terminate or signal the system `fseventsd` process;
- delete or modify `.fseventsd` data;
- generate pressure in a user's home directory or another production volume;
- require root privileges or private APIs;
- claim genuine daemon qualification from an injected flag or application-buffer overflow;
- make a flaky daemon-pressure experiment part of the default CI gate.

## 6. Release interpretation

Until genuine daemon evidence is captured, release notes and health UI must say that continuity-loss handling is implemented and semantically qualified, while daemon-specific drop/wrap reproduction remains unqualified. This limitation does not permit SpaceTrace to skip reconciliation: every observed continuity gap still schedules conservative calibration.
