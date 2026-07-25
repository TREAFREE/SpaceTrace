# Background Soak Qualification

Status: **Diagnostic infrastructure implemented; real 24-hour host matrices remain open**

Last reviewed: 2026-07-25

Chinese translation: [后台长时间运行资格验证](background-soak-qualification.zh-CN.md)

## Purpose

This protocol turns a signed, sandboxed SpaceTrace run into bounded local
evidence for the background storage lifecycle. It is deliberately opt-in and
does not change the product's default telemetry posture.

The implementation provides:

- an application-owned recorder that observes the existing background
  coordinator rather than creating another scheduler;
- one path-free JSON object per lifecycle state transition and 60-second
  heartbeat;
- current process CPU time, resident memory, aggregate SQLite/WAL/SHM size,
  capacity-history sequence, typed qualification state, sampling failures,
  retention outcome, and wake recovery latency;
- a two-segment writer capped at 10 MiB total and seven days, with `0700`
  directory and `0600` file permissions;
- a menu-bar indicator whenever diagnostic recording is active; and
- a deterministic analyzer with a machine-readable JSON report and non-zero
  failure exit status.

It does not upload data, generate a stable device identifier, prevent sleep,
or claim that a short run is equivalent to a 24-hour qualification.

## Privacy contract

The diagnostic schema is intentionally unable to represent:

- watched paths, file names, volume names, volume UUIDs, or bookmarks;
- available-space byte values or directory measurement rows;
- environment variables, command-line arguments, user identity, or contact
  data; or
- file contents.

Each process launch gets a random session UUID. It is only a run-correlation
value and is not persisted outside the bounded log. Timing and usage behavior
remain sensitive local diagnostic data even without paths.

| Field group | Classification | Purpose | Retention/export | Deletion |
| --- | --- | --- | --- | --- |
| Wall/continuous time, random session ID | Sensitive local diagnostic | Order events, measure real duration across sleep, correlate one launch | Local only; at most 7 days / 10 MiB; included only if the user manually copies it | Automatic segment expiry/rotation or deletion of the diagnostic directory |
| Lifecycle phase, trigger, counters, failures, retention boolean | Sensitive local diagnostic | Prove sleep/wake, recovery, and maintenance behavior | Same bounded policy | Same |
| Capacity sequence and typed qualification | Sensitive local diagnostic | Detect regression and prove the final 24-hour state without exposing volume identity or bytes | Same bounded policy | Same |
| Cumulative CPU time, resident memory, aggregate database bytes | Sensitive local diagnostic | Check the NFR budgets and growth trend | Same bounded policy | Same |

No automatic export or network transport exists.

## Enabling a qualification run

Diagnostic recording is off unless the launched process receives exactly:

```text
SPACETRACE_BACKGROUND_SOAK_DIAGNOSTICS=1
```

The app stores the files inside its sandboxed Application Support directory:

```text
SpaceTrace/Diagnostics/BackgroundQualification/
```

The menu bar then displays a persistent local-recording notice. If the writer
cannot be created, monitoring continues without diagnostics and the indicator
does not claim that recording is active.

Use a signed sandbox build for release evidence. An ad-hoc signed build is
acceptable for a current-host engineering smoke, but it is not Developer ID
distribution evidence.

## Analyzer

Build and test the qualification tooling:

```bash
make package-background-soak-qualification
```

Analyze a completed directory:

```bash
swift run --package-path Packages/SpaceTraceKit \
  SpaceTraceSoakAnalyzer \
  --input "/path/to/BackgroundQualification" \
  --output "/path/to/qualification-report.json"
```

For the signed-app preflight and analysis in one fail-closed command:

```bash
Scripts/qualify-background-soak.sh \
  "/path/to/SpaceTrace.app" \
  "/path/to/BackgroundQualification" \
  "/path/to/qualification-report.json"
```

The existing `SPACETRACE_ALLOW_NEWER_HOST_SMOKE` and
`SPACETRACE_ALLOW_ADHOC_SMOKE` flags are accepted only for a clearly labeled
non-qualifying preflight. `SPACETRACE_SOAK_SMOKE_SECONDS` additionally selects
the analyzer's smoke policy.

The default policy fails unless the evidence has:

- at least 24 hours of non-regressing continuous-clock duration;
- no unbracketed awake heartbeat gap greater than five minutes;
- non-decreasing capacity sequence;
- a final `qualified` capacity state and no remaining consecutive sample
  failure;
- at least one successful retention outcome;
- wake-to-published-state latency no greater than 10 seconds;
- resident memory no greater than 150 MB;
- aggregate main database, WAL, and SHM size no greater than 250 MB; and
- average CPU ratio no greater than 0.5% and p95 interval ratio no greater than
  2%.

For plumbing-only tests, `--smoke <minimum-seconds>` relaxes the 24-hour,
retention, final-capacity, and CPU requirements. A smoke result must never be
used as a release qualification result.

## Required real matrix

Run the default analyzer after each signed sandbox run:

| Host | Duration | Required transitions | Status |
| --- | ---: | --- | --- |
| Current stable macOS on Apple Silicon | At least 24 h | launch, ordinary operation, real sleep/wake, time change, time-zone change, local midnight, quit/relaunch | Open |
| macOS 15.6 on Apple Silicon | At least 24 h | Same matrix | Open |

For each host:

1. Keep normal system sleep enabled.
2. Exercise both AC and battery operation; include Low Power Mode if available.
3. Verify the menu bar changes to qualified only after valid persisted
   evidence and falls back after an actual gap.
4. Save the analyzer report and build/signature metadata.
5. Use Instruments/Energy Log or an equivalent Apple-supported profiler for
   energy evidence. Internal cumulative CPU time is not an energy measurement.
6. Inspect log size, file modes, database growth, and the absence of path-like
   content before accepting the result.

Compiling with a 15.6 deployment target on a newer macOS host does not satisfy
the macOS 15.6 runtime row.

## Current-host smoke evidence

On 2026-07-25, an independently identified Release app was ad-hoc signed and
run inside App Sandbox on Apple Silicon macOS 26.5.2 with diagnostics enabled.
The non-qualifying 120-second smoke policy passed:

- signature and designated requirement verified; the three required sandbox
  entitlements and `LSMinimumSystemVersion = 15.6` were present;
- 7 records covered 241.636 seconds, including normal application shutdown;
- average measured CPU ratio was 0.0344% and p95 was 0.0907% after excluding
  sub-10-second lifecycle bursts from interval percentiles;
- maximum resident memory was 135,495,680 bytes and aggregate database size
  was 263,496 bytes;
- the log was 3,585 bytes; directory/file modes were `0700`/`0600`; and
- a forbidden-field scan found no user path, bookmark, volume identity,
  capacity-value, environment, command-line, or file-name field.

This smoke proves signed-sandbox wiring, heartbeat, resource probing, normal
shutdown, protected persistence, and analyzer interoperability on that host.
It does **not** include sleep/wake, retention delivery, energy profiling,
24-hour capacity qualification, an Apple signing identity, or macOS 15.6
runtime evidence.

## Automated coverage

Deterministic tests cover healthy qualification, fail-closed resource and
sequence boundaries, sleep-bracketed versus awake gaps, schema privacy,
retention expiry, two-segment rotation, POSIX protection, native process
resource probing, and the menu-bar enabled indicator. The package also passes
the complete strict-concurrency warning audit.

These tests qualify the implementation logic. Only the real matrix can qualify
long-running scheduler, sleep/wake, energy, and minimum-OS behavior.
