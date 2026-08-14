# Background Soak Qualification

Status: **Current-host ad-hoc endurance passed; final-RC macOS 15.6 matrix remains open**

Last reviewed: 2026-08-14

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

Use the exact manifest-bound signed sandbox RC for release evidence. The
maintainer-approved Public Beta is ad-hoc signed and unnotarized; that truth is
accepted only for this explicitly disclosed Beta and is not Developer ID,
notarization, publisher-identity, or future stable-release evidence.

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
  "/path/to/SpaceTrace-0.1.0-beta.1.app" \
  "/path/to/SpaceTrace-0.1.0-beta.1.manifest.json" \
  "/path/to/BackgroundQualification" \
  "/path/to/qualification-report.json" \
  "/path/to/minimum-os-preflight.json"
```

`SPACETRACE_SOAK_SMOKE_SECONDS` selects both the analyzer's smoke policy and
the explicit newer-host preflight mode. The wrapper then reports `SMOKE`, not
`PASS`; the old signing/host override environment variables are no longer
accepted. Without the smoke policy, only a macOS 15.6.x arm64 preflight receipt
can proceed to a qualifying analysis.

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
| Current stable macOS on Apple Silicon | At least 24 h | launch, ordinary operation, real sleep/wake, time change, time-zone change, local midnight, quit/relaunch | 2026-07-30 ad-hoc endurance passed; explicit time/time-zone, signed status-item, and Release Candidate replacement rows remain open |
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

The current-host runner keeps the application diagnostic continuous but bounds
Instruments storage by recording five representative five-minute Activity
Monitor slices at 0, 6, 12, 18, and 24 hours:

```bash
Scripts/run-current-host-soak.sh start \
  "/path/to/SpaceTrace-0.1.0-beta.1.app" \
  "/path/to/SpaceTrace-0.1.0-beta.1.manifest.json" \
  "$HOME/Library/Application Support/SpaceTraceQualification/<run-id>" \
  90000
```

Create the evidence directory first and keep it outside Desktop, Documents, and
Downloads. The detached launchd worker does not inherit Terminal/Codex access
to those privacy-protected folders. The runner copies an immutable app,
analyzer, and worker into the evidence directory before launch. It bootstraps
an explicit per-run LaunchAgent plist with `RunAtLoad=true` and
`KeepAlive=false`; an unsuccessful worker must terminate as `FAILED`, not be
silently relaunched.

Query the detached supervisor without interrupting it:

```bash
Scripts/run-current-host-soak.sh status \
  "/path/to/evidence-directory"
```

The detached worker now performs normal application termination,
protected-storage inspection, privacy scanning, and default 24-hour analysis
immediately after the run window. A terminal state is `PASSED` or `FAILED`.
The manual command is retained only as a recovery tool for an older/interrupted
run that stopped at `READY_TO_FINALIZE`:

```bash
Scripts/run-current-host-soak.sh finalize \
  "/path/to/evidence-directory"
```

The 25-hour wall-clock window leaves one hour after the final 24-hour slice
for graceful shutdown and final analysis. It never disables system sleep.
Each Instruments slice exports its table of contents, process ledger, live
process series, and thermal intervals. Those tables provide CPU
percentage/time, idle wakeups, physical memory, disk reads/writes, App Nap,
sleep-prevention state, and system thermal state.

On Xcode 26, the listed `Power Profiler` instrument rejects macOS targets and
states that it supports only iOS/iPadOS; the older `Energy Log` template is not
installed. Therefore Activity Monitor data is accepted only as
**energy-related process evidence**, not direct joule/watt measurement.
`powermetrics --show-process-energy` can supplement estimated SoC power and
Energy Impact, but requires an interactive superuser authorization. Its own
documentation warns that estimated power is unsuitable for cross-device
comparisons. Missing authorization must remain a declared evidence gap.
Every run also records the installed-template list and fresh Power Profiler /
unprivileged `powermetrics` support probes in `energy-capability.txt`.

Compiling with a 15.6 deployment target on a newer macOS host does not satisfy
the macOS 15.6 runtime row.

## 2026-07-27 current-host run: captured, not qualified

An independently identified ad-hoc signed Release/App Sandbox build ran on a
MacBook Air with Apple Silicon and macOS 26.5.2. The app had only App Sandbox,
read-only user-selected files, and app-scoped bookmark entitlements, with
`LSMinimumSystemVersion = 15.6`. This is current-host engineering evidence,
not Developer ID, notarization, distribution, or macOS 15.6 runtime evidence.

The default analyzer correctly failed closed:

- one session and 1,693 path-free records covered 168,945,297 ms
  (46 h 55 min 45.297 s); the older runner waited for manual finalization, so
  the app continued past its intended 25-hour window;
- `final_capacity_not_qualified` was genuine: a long sleep interval left no
  baseline sample within the 24-hour endpoint tolerance, and only about
  1.5 hours of fresh awake history existed before shutdown;
- `wake_recovery_budget_exceeded` exposed a recorder defect rather than a
  genuine 30-hour recovery. A successful wake remained the state's last sample
  trigger, so later deferred-maintenance publications repeatedly recomputed
  elapsed time from that old wake. Immediate wake publications in the raw
  evidence were within 0–198 ms, but the official run remains failed and must
  be repeated with the corrected recorder;
- the other analyzer evidence stayed within budget: maximum awake heartbeat
  gap 62,047 ms, maximum RSS 141,115,392 bytes, maximum database size
  350,016 bytes, average CPU ratio 0.00624%, p95 interval CPU ratio 0.02325%,
  no remaining sample failures, and successful retention observed; and
- the bounded diagnostic directory was about 900 KiB with `0700`/`0600`
  protection, while the forbidden-field scan was empty.

All five Activity Monitor recordings and exports completed without capture
failure. Across the five five-minute live series (25 bounded minutes):

| Metric | Evidence |
| --- | ---: |
| CPU time | 0.493001 s |
| Per-slice mean CPU | 0.011914%–0.038800% |
| Per-slice p95 CPU | 0.023103%–0.073675% |
| Highest instantaneous CPU | 2.843294% during the launch slice |
| Idle wakeups | 1,180 total, about 0.79/s |
| Disk writes / reads | 2,023,424 / 155,648 bytes |
| Maximum physical footprint | 53,068,760 bytes |
| App Nap | observed in the four post-launch slices |
| Preventing Sleep | never observed |
| Thermal State | Nominal in all five slices |

These are energy-related process-resource measurements, not watt/joule
measurements. Power Profiler rejected the macOS target, and unprivileged
`powermetrics` required superuser authorization.

The evidence drove four fail-closed changes: wake recovery is emitted once per
new successful wake; a retention opportunity deferred during sleep is
acknowledged once and replayed after the genuine wake instead of asking the
system for rapid retries; thermal XML is exported automatically; and the
detached worker now finalizes at the end of the window using only system-path
tools. A 60-second detached regression then passed automatic normal quit,
thermal export, real privacy scanning, analyzer execution, and launchd cleanup.
The capacity-history contract now also persists schema-v10 sleep/wake
boundaries: only a strictly adjacent boundary pair can explain a long interval,
while awake, missing, one-sided, and process-termination gaps still fail
closed. Its v9 migration, rollback, and 24-hour query branches have
deterministic regression coverage.
The current-host matrix row remains open until a new default-policy run passes.

## 2026-07-29 current-host rerun: externally interrupted

The schema-v10 build at commit `3ae4f24` started with a separate ad-hoc signed
Release/App Sandbox identity. Signature preflight, all three required
entitlements, `LSMinimumSystemVersion = 15.6`, diagnostics, and the first
Activity Monitor attachment succeeded.

The app then completed an orderly `exit(0)` after 212.012 seconds. Its path-free
log contains one session, three heartbeats, and a final `stopped` record with
no sample failure. There is no matching crash report or signal termination,
and the retained unified log does not identify the external normal-termination
request. The supervisor correctly detected that the app exited before the
qualification endpoint. The host later shut down at 2026-07-30 01:11 and
rebooted at 09:36, which independently makes the attempted wall-clock run
ineligible. This evidence is an interrupted run, not a failed product
reliability claim and not a 24-hour result.

The interruption exposed two runner defects. The zsh `EXIT` trap referenced
function-local state after that scope had ended, leaving the persisted status
as `RUNNING`; and `launchctl submit` inferred `KeepAlive`, so a nonzero worker
could be relaunched. The runner now uses script-lifetime cleanup state, writes
a protected typed failure summary, derives a failure for legacy orphaned
`RUNNING` state, and bootstraps a non-restarting per-run LaunchAgent.

Two independent signed-sandbox regressions exercise both terminal paths:

- a controlled early `exit(0)` writes `FAILED` with
  `failure_reason=app_exited_before_qualification_end`, removes the App and
  supervisor, and does not relaunch; and
- an uninterrupted 60-second smoke writes `PASSED`, with zero capture
  failures, an empty privacy scan, analyzer exit status 0, one session/four
  records over 59,737 ms, 139,509,760-byte maximum RSS, 292,336-byte maximum
  database size, and no remaining launchd job.

These smokes qualify runner plumbing only. The current-host 24-hour row remains
open, and its next run requires normal sleep to remain enabled while the user
does not shut down, log out, or quit SpaceTrace.

## 2026-07-30 current-host rerun: passed

The hardened runner started commit `ed0d660` at 2026-07-30 16:00:58 UTC with
an independent bundle identifier, ad-hoc signature, Release configuration, and
App Sandbox on Apple Silicon macOS 26.5.2. It ended automatically at
2026-07-31 17:09:52 UTC. The preflight verified the copied runtime bundle and
`LSMinimumSystemVersion = 15.6`; this remains current-host engineering evidence,
not Developer ID, notarization, distribution, or macOS 15.6 runtime evidence.

The terminal artifacts report `PASSED`, zero capture failures, an empty
forbidden-field scan, and analyzer exit status 0. One session produced 794
path-free records covering 90,529,656 ms (25 h 8 min 49.656 s). The default
policy found no issue:

| Analyzer metric | Evidence | Budget |
| --- | ---: | ---: |
| Maximum awake heartbeat gap | 62,097 ms | 300,000 ms |
| Maximum wake recovery | 1 ms | 10,000 ms |
| Maximum resident memory | 139,984,896 bytes | 150,000,000 bytes |
| Maximum aggregate database | 613,696 bytes | 250,000,000 bytes |
| Average CPU | 0.011710% | 0.5% |
| p95 interval CPU | 0.039200% | 2% |

Successful retention and a final qualified capacity endpoint were both
observed. The bounded diagnostics occupied about 452 KiB, retained `0700`
directory and `0600` file protection, and contained none of the prohibited
path, bookmark, volume, capacity-value, environment, command-line, or file-name
fields.

All five requested Activity Monitor captures and their ledger/live/thermal
exports completed. A typed analyzer added after the run resolves xctrace
`id`/`ref` cells and fails closed on missing companions, counter regression,
or inconsistent ledgers. Re-analysis of the retained exports produced a
3,457-byte protected JSON report with SHA-256
`759627dd8ad595d79a06821cfefd2e0d192ed67d50f562d495fc63289920bc44`:

| Instruments metric | Evidence |
| --- | ---: |
| CPU time across captured intervals | 0.401045252 s |
| Per-slice mean CPU | 0.011421%–0.033809% |
| Per-slice p95 CPU | 0.022102%–0.126791% |
| Highest instantaneous CPU | 1.507951% |
| Idle wakeups | 959 |
| Disk writes / reads | 811,008 / 352,256 bytes |
| Maximum physical footprint | 99,271,664 bytes |
| App Nap | observed in 3 of 5 slices |
| Preventing Sleep | never observed |
| Thermal State | Nominal in all five slices |

The five nominal five-minute capture requests include system-sleep gaps in
their exported live intervals; the analyzer therefore uses actual rows and
cumulative-counter deltas rather than assuming exactly 25 elapsed minutes.
These are energy-related process-resource measurements, not watt/joule
measurements. The same evidence directory records that Power Profiler rejects
macOS targets and unprivileged `powermetrics` requires interactive superuser
authorization. The current-host ad-hoc 24-hour gate is closed; direct power,
Apple-identity, release-candidate, and macOS 15.6 runtime gates remain open.

On 2026-08-10, a separate 60-second ad-hoc Release/App Sandbox regression
exercised the new dual-analyzer finalization path. It produced `PASSED`, five
path-free records over 59,392 ms, one complete Activity Monitor slice, zero
capture failures, privacy `PASS`, both analyzer exit statuses 0, `0600` report
files, and no residual App or launchd job. This qualifies the new runner
plumbing only and does not replace any endurance or release matrix row.

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
