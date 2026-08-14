# SpaceTrace Release Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the successful current-host endurance evidence, restore repeatable UI qualification, and produce a reproducible unsigned Release Candidate without overstating signing or minimum-OS support.

**Architecture:** Qualification tooling remains outside the shipping application and consumes only bounded, path-free diagnostics plus exported Instruments XML. Release packaging consumes a clean Release archive and emits immutable checksums and verification metadata; it does not change runtime entitlements. Environment-gated macOS 15.6, Apple-identity, notarization, and direct power measurements remain explicit open gates.

**Tech Stack:** Swift 6 package tooling, Swift Testing, Foundation `XMLParser`, zsh qualification scripts, Xcode 26 command-line tools, Activity Monitor Instruments, SwiftUI/XCTest UI tests, `codesign`, `hdiutil`, SHA-256.

## Global Constraints

- Minimum runtime remains macOS 15.6 on Apple Silicon; a newer-host run is not macOS 15.6 runtime qualification.
- App Sandbox and app-scoped bookmarks remain. ADR-007 supersedes this plan's
  original entitlement assumption: user-selected read/write is allowed only
  for the exact diagnostic save-panel destination, while watched bookmarks
  remain explicitly read-only.
- Activity Monitor CPU, wakeup, memory, I/O, App Nap, sleep assertion, and thermal data are energy-related process evidence, not watt/joule evidence.
- Qualification reports and committed fixtures must not contain user paths, file names, bookmark data, volume identity, capacity values, command lines, or environment values.
- No Developer ID, notarization, Apple-identity, or automatic-update claim may be made without the corresponding real credential and matrix evidence.
- Each task ends with fresh focused verification, `make verify`, documentation updates, and a scoped Chinese commit.

---

## File Structure

- `Packages/SpaceTraceKit/Sources/SpaceTraceQualification/InstrumentsActivityMonitorReport.swift`: parse exported xctrace tables and calculate deterministic process-resource evidence.
- `Packages/SpaceTraceKit/Sources/SpaceTraceQualification/XctraceTableParser.swift`: resolve xctrace XML schema columns and `id`/`ref` cell values without retaining source paths.
- `Packages/SpaceTraceKit/Sources/SpaceTraceInstrumentsAnalyzer/main.swift`: command-line boundary for reading an evidence directory and atomically writing JSON.
- `Packages/SpaceTraceKit/Tests/SpaceTraceQualificationTests/InstrumentsActivityMonitorReportTests.swift`: reference-resolution, aggregation, percentile, and fail-closed fixtures.
- `Scripts/run-current-host-soak.sh`: build, preserve, execute, and gate the Instruments summarizer for future runs.
- `SpaceTraceUITests/DirectoryAuthorizationUITests.swift`: release UI journeys once the host can initialize a signed UI runner.
- `Scripts/package-release-candidate.sh`: reproducible archive, DMG, checksum, signature inspection, and release manifest generation.
- `docs/engineering/background-soak-qualification*.md`: current-host endurance result and evidence boundary.
- `docs/engineering/release-candidate-checklist*.md`: installation, Gatekeeper, permission restoration, upgrade, and rollback matrix.
- `docs/engineering/implementation-status*.md`: accepted evidence and remaining gates.

### Task 1: Close Current-Host Endurance and Instruments Evidence

**Files:**
- Modify: `Packages/SpaceTraceKit/Package.swift`
- Create: `Packages/SpaceTraceKit/Sources/SpaceTraceQualification/InstrumentsActivityMonitorReport.swift`
- Create: `Packages/SpaceTraceKit/Sources/SpaceTraceInstrumentsAnalyzer/main.swift`
- Create: `Packages/SpaceTraceKit/Tests/SpaceTraceQualificationTests/InstrumentsActivityMonitorReportTests.swift`
- Modify: `Scripts/run-current-host-soak.sh`
- Modify: `Makefile`
- Modify: `docs/engineering/background-soak-qualification.md`
- Modify: `docs/engineering/background-soak-qualification.zh-CN.md`
- Modify: `docs/engineering/implementation-status.md`
- Modify: `docs/engineering/implementation-status.zh-CN.md`

**Interfaces:**
- Consumes: exported `*-ledger.xml`, `*-live.xml`, and `*-thermal.xml` files from one qualification run.
- Produces: `InstrumentsActivityMonitorReport` and `reports/instruments-report.json`; future soak finalization requires the analyzer to succeed.

- [x] **Step 1: Write reference-resolution and aggregation tests**

```swift
let report = try InstrumentsActivityMonitorAnalyzer().analyze(directory: fixtureURL)
#expect(report.sliceCount == 2)
#expect(report.totalCPUTimeNanoseconds == 300_000_000)
#expect(report.totalIdleWakeups == 5)
#expect(report.maximumPhysicalFootprintBytes == 60_000_000)
#expect(report.preventingSleepObserved == false)
#expect(report.thermalStates == ["Nominal"])
```

- [x] **Step 2: Run the focused tests and confirm the missing module fails**

Run: `swift test --package-path Packages/SpaceTraceKit --filter InstrumentsActivityMonitorReportTests`

Expected: FAIL because `SpaceTraceQualification` and its analyzer do not yet exist.

- [x] **Step 3: Implement the typed XML parser and report**

```swift
public struct InstrumentsActivityMonitorAnalyzer: Sendable {
    public init() {}
    public func analyze(directory: URL) throws -> InstrumentsActivityMonitorReport
}
```

Resolve xctrace `id`/`ref` cells, map direct row cells by schema mnemonic, reject missing slice trios or unusable rows, calculate per-slice CPU mean/p95/max and cumulative deltas, and preserve only aggregate numeric or enum-like evidence.

- [x] **Step 4: Add the CLI and runner gate**

Run the executable as:

```bash
SpaceTraceInstrumentsAnalyzer \
  --input "/absolute/evidence/instruments" \
  --output "/absolute/evidence/reports/instruments-report.json"
```

Future `finalize` succeeds only when capture exports, privacy scan, soak analyzer, and Instruments analyzer all exit successfully.

- [x] **Step 5: Analyze the completed 2026-07-30 run and update evidence docs**

Run the CLI against `20260730-current-host-25h-v3`, compare JSON to the raw ledgers, live rows, thermal rows, terminal status, and path-free report, then document exact results and explicit non-claims in English and Chinese.

- [x] **Step 6: Verify and commit**

Run:

```bash
swift test --package-path Packages/SpaceTraceKit --filter InstrumentsActivityMonitorReportTests
make package-background-soak-qualification
make verify
git diff --check
```

Commit: `收口当前主机长跑与 Instruments 证据`

### Task 2: Restore UI and Accessibility Qualification

**Files:**
- Modify: `SpaceTraceUITests/DirectoryAuthorizationUITests.swift`
- Modify: `CONTRIBUTING.md`
- Modify: `docs/product/visual-design-system.md`
- Modify: `docs/product/visual-design-system.zh-CN.md`
- Modify: `docs/engineering/implementation-status.md`
- Modify: `docs/engineering/implementation-status.zh-CN.md`

**Interfaces:**
- Consumes: existing controlled UI scenarios and a host capable of launching the local sandbox UI runner.
- Produces: repeatable UI-runner evidence for authorization states, history gaps, key action names/hittability, and accessibility values.

- [x] **Step 1: Record the host prerequisite without mutating it**

Run: `/usr/sbin/DevToolsSecurity -status` and `security find-identity -v -p codesigning`.

Expected: either a usable UI-test environment or a typed blocked result. Enabling Developer Mode or adding an identity requires explicit owner action.

Result: `security find-identity -v -p codesigning` reported zero stable Apple identities and `DevToolsSecurity -status` did not return a usable status on this host. Xcode 26.1.1 nevertheless established a real automation session using local ad-hoc “Sign to Run Locally” signatures, so the controlled current-host fixture was usable without changing system security settings.

- [x] **Step 2: Add focused accessibility assertions before implementation changes**

The new test was observed failing first for missing accessibility exposure, then passing after stable privacy semantics and action hints were added. The authorized fixture now also asserts the replacement and revocation actions' exact names and hittability.

- [x] **Step 3: Execute the complete automated UI matrix and bound its claim**

The fresh Xcode UI runner passed all eight `DirectoryAuthorizationUITests` scenarios on macOS 26.5.2. This proves the controlled fixture's names, values, hittability, authorization-state projection, and no-fabricated-history behavior. Manual VoiceOver speech, Full Keyboard Access traversal, increased contrast, reduced motion, and larger system text remain explicitly open release-matrix work; no system accessibility preference was silently changed.

- [x] **Step 4: Verify and commit**

Run `make verify`, the complete UI command, and `git diff --check`.

Result: `make verify` passed with 247 package tests in 38 suites, the strict-concurrency audit, 24 application unit tests, and Debug/Release builds. After Xcode cleaned DerivedData left by the repository relocation, the repository-standard `make app-test-ui` entry point passed all eight scenarios.

Commit: `补齐界面与无障碍资格验证`

### Task 3: Build a Reproducible Unsigned Release Candidate

**Files:**
- Create: `Scripts/package-release-candidate.sh`
- Create: `Scripts/test-release-candidate-packaging.sh`
- Create: `Scripts/qualify-release-candidate.sh`
- Create: `docs/engineering/release-candidate-checklist.md`
- Create: `docs/engineering/release-candidate-checklist.zh-CN.md`
- Modify: `Makefile`
- Modify: `SpaceTrace.xcodeproj/project.pbxproj`
- Modify: `README.md`
- Modify: `docs/README.md`
- Modify: `docs/engineering/direct-distribution-signing.md`
- Modify: `docs/engineering/direct-distribution-signing.zh-CN.md`
- Modify: `docs/engineering/implementation-status.md`
- Modify: `docs/engineering/implementation-status.zh-CN.md`

**Interfaces:**
- Consumes: clean source commit, Release build, explicit semantic version, and immutable bundle identifier.
- Produces: `.app`, `.dmg`, `.sha256`, and JSON manifest clearly marked `adhoc` or `unsigned`; no GitHub Release is created by this task.

- [x] **Step 1: Add packaging-script contract tests using a disposable output directory**

```bash
Scripts/package-release-candidate.sh \
  --version 0.1.0-rc.1 \
  --output "$TMPDIR/spacetrace-rc"
```

Assert an exact artifact set, matching SHA-256, expected entitlements, `LSMinimumSystemVersion=15.6`, arm64 architecture, and a manifest that does not claim Developer ID or notarization.

- [x] **Step 2: Implement fail-closed packaging**

Reject dirty source, missing version, unexpected signing authority, entitlement drift, wrong deployment target, existing output, and a failed Release build. Stage a read-only compressed DMG without altering user data or installing anything.

- [x] **Step 3: Execute the non-interactive installation/replacement subset and record open rows**

Two independently packaged binaries from commit `f2119be` passed fresh launch, same-build restart, and replacement launch under one disposable identity. `spctl` rejected the unnotarized app as expected. No directory was selected, so bookmark, denied-permission, stale, and external-volume RC rows remain open. macOS privacy denied removal of the exact disposable container; the typed blocker, residual path, and owner-authorized removal boundary are documented rather than bypassed.

- [x] **Step 4: Verify and commit**

Run `make verify`, packaging verification twice from the same commit, checksum validation, `codesign --verify --deep --strict`, `spctl --assess` with the expected non-notarized result, and `git diff --check`.

Result: `make verify` passed with 247 package tests in 38 suites, the strict-concurrency audit, 24 application unit tests, and Debug/Release builds. Two independent packages from commit `f2119be` passed their checksums and strict code-sign verification; their DMG SHA-256 values were intentionally distinct and individually recorded. `spctl` returned 3/`rejected`, matching the manifest's unnotarized ad-hoc disclosure.

Commit: `建立未签名发布候选打包流程`

### Task 4: Release Decision Gate

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/product/product-roadmap.md`
- Modify: `docs/engineering/implementation-status.md`
- Modify: `docs/engineering/implementation-status.zh-CN.md`

**Interfaces:**
- Consumes: Tasks 1–3 evidence plus macOS 15.6 and Apple-identity matrix status.
- Produces: an explicit `GO`, `CONDITIONAL GO`, or `NO-GO` record; publishing remains a separate owner-authorized action.

- [x] **Step 1: Reconcile every Public Beta and RC gate**

Mark current-host endurance, UI accessibility, macOS 15.6 runtime, ADR review, signing/notarization, fresh install, update/replacement, database migration, and rollback as passed, blocked, or open with linked evidence.

- [x] **Step 2: Prepare release notes without publishing**

State supported architecture/system, permission model, unsigned-install friction, known gaps, data location/removal, checksum verification, and rollback behavior. Do not create a Git tag, GitHub Release, or upload artifact.

- [x] **Step 3: Verify and commit**

Run `make verify`, documentation link checks, `git diff --check`, and review the gate table line by line.

Result: `make verify` passed with 247 package tests in 38 suites, the strict-concurrency audit, 24 application unit tests, and Debug/Release builds. Local documentation links and `git diff --check` passed. The gate table was reconciled against the PRD Public Beta gates, current implementation evidence, ADR statuses, artifact qualification, and absent license/signing/minimum-OS/user-research evidence.

Commit: `形成首个发布候选决策记录`

## Self-Review

- Spec coverage: endurance/Instruments, UI/accessibility, reproducible DMG, replacement/install behavior, and release decision are each owned by a separate testable task.
- Privacy: only synthetic XML is committed; real diagnostics and raw Instruments traces remain local evidence.
- Type consistency: Task 1 consistently produces `InstrumentsActivityMonitorReport` through `InstrumentsActivityMonitorAnalyzer` and `SpaceTraceInstrumentsAnalyzer`.
- Scope boundary: Developer Mode, signing identities, notarization, macOS 15.6 runtime, and GitHub publishing are not silently enabled or claimed.
