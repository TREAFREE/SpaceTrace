# Background Storage Sampling Lifecycle and Menu Bar

Status: **Implemented phase-one slice; host and minimum-OS qualification remains open**

Last reviewed: 2026-07-29

Chinese translation: [后台空间采样生命周期与菜单栏](background-storage-sampling-lifecycle.zh-CN.md)

## Purpose

This slice turns startup-volume capacity history from a simple launch/hourly
loop into an application-owned lifecycle. It also exposes a 24-hour menu-bar
result only when the persisted evidence supports that comparison.

The implementation does not claim that macOS will wake a terminated app every
hour. SpaceTrace samples while its process is running, samples immediately
after launch and wake, and uses a system-scheduled opportunity for deferrable
retention. Missing process time remains a visible history gap.

## Ownership

| Layer | Responsibility |
| --- | --- |
| `SpaceTraceApplication` | Typed lifecycle events, serialized sampling/retention coordinator, bounded observable state, and the 24-hour qualification query |
| `SpaceTracePlatform` | `NSWorkspace` sleep/wake notifications, system clock/time-zone notifications, an hourly in-process timer, and `NSBackgroundActivityScheduler` retention opportunities |
| `SpaceTracePersistence` | Monotonic-sequence capacity reads and the existing deterministic 30-day retention transaction |
| App target | Starts and stops the lifecycle, observes health, and presents qualified or explicitly incomplete evidence in `MenuBarExtra` |

Native callbacks enqueue immutable application events. They never query or
write SQLite directly. One coordinator worker serializes capacity sampling and
retention, so a wake, time-change, periodic tick, and maintenance opportunity
cannot overlap persistence work.

## Lifecycle contract

1. Process start records an immediate startup-volume observation.
2. While awake and running, a periodic event is requested every hour.
3. `willSleep` first commits a capacity observation tagged `sleep_boundary`,
   then changes the coordinator to sleeping; periodic, time-change, and
   maintenance work is deferred without writing.
4. `didWake` returns to awake and immediately commits a `wake_boundary`
   observation. This closes the common
   “wake now, wait nearly one hour for the next timer” blind spot.
5. A system clock or time-zone change records immediately while awake. The
   database sequence remains the ordering authority; a wall-clock rollback is
   preserved as a discontinuity rather than sorted away.
6. Retention is requested daily through `NSBackgroundActivityScheduler` with a
   one-hour tolerance. It is single-flight and deferrable. The existing
   retention transaction remains deterministic and receives the captured
   reference time.
7. Shutdown stops native producers first, drains the application coordinator,
   then closes authorization and monitoring ownership.

The platform monitor uses public APIs documented by Apple:
[`NSWorkspace`](https://developer.apple.com/documentation/appkit/nsworkspace),
[`didWakeNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification),
and
[`NSBackgroundActivityScheduler`](https://developer.apple.com/documentation/foundation/nsbackgroundactivityscheduler).

## Reliable 24-hour result

The menu bar query reads the newest persisted observations in monotonic commit
order. A specific signed change is shown only when all of these conditions hold:

- the newest observation is current and has a startup-volume UUID and available
  byte value;
- a baseline exists near the 24-hour endpoint;
- adjacent observations have no gap greater than 90 minutes, except a strictly
  adjacent persisted `sleep_boundary → wake_boundary` pair; an unmarked,
  one-sided, or process-termination gap still fails closed;
- commit order contains no wall-clock rollback;
- the startup-volume identity does not change in the comparison epoch;
- the bounded query did not truncate the evidence needed for the endpoint.

Any failure becomes a typed state: collecting, stale, sampling gap, clock
discontinuity, volume identity change, history-limit reached, or unavailable.
The UI then shows **insufficient evidence**, not zero and not a cached prior
delta. It separately shows current available space, last capacity sample, last
directory reconciliation, scan/authorization health, and a sampling-failure
warning.

`MenuBarExtra` is presentation only. It does not own the timer, lifecycle
notifications, database connection, or retention scheduler.

## Automated evidence

Run:

```bash
make package-background-lifecycle-qualification
```

The deterministic suites cover:

- sleep/wake boundary persistence, sleep suppressing periodic writes, and wake
  sampling immediately;
- clock and time-zone changes, including deferral while asleep;
- sampling failure visibility and later recovery;
- failed retention followed by a later successful scheduled attempt;
- 30 virtual days / 720 hourly ticks, including sleep/wake and time-change
  events, 30 retention opportunities, bounded state, and serialized work;
- qualified 24-hour results plus genuine sleep-boundary acceptance and
  awake-gap, stale, rollback, volume replacement, unavailable, and
  insufficient-history rejection;
- atomic v9-to-v10 capacity-table migration, rollback on injected
  pre-commit failure, and the reviewed v9 golden fixture;
- a real SQLite 25-sample path from persistence through the 24-hour query;
- native notification-to-typed-event adaptation; and
- MainActor menu-bar projection and fail-closed refresh behavior.

The virtual-time run is a deterministic long-duration logic qualification. The
opt-in, path-free recorder and analyzer described in the
[background soak qualification protocol](background-soak-qualification.md)
now make the remaining real run reproducible. Neither is **evidence by itself**
of a real 24-hour process soak, energy budget, scheduler delivery guarantee,
memory plateau, or macOS 15.6 runtime behavior.

## Remaining release qualification

Before claiming the reliability release gate:

1. Run a signed sandbox build continuously for at least 24 hours on the current
   stable macOS and on Apple Silicon macOS 15.6.
2. Include real sleep/wake, clock and time-zone changes, and an interval that
   crosses local midnight.
3. Record sample sequence, observed time, wake-to-sample latency, retention
   outcome, CPU, memory, energy, and database growth without collecting watched
   paths in diagnostics.
4. Verify the menu bar changes from collecting to qualified only after a
   continuous window, and falls back after a real gap or identity change.
5. Complete the signed system status-item interaction and accessibility matrix.

Until that matrix passes, this slice is implemented and deterministically
qualified, but it does not make SpaceTrace beta- or release-qualified.
