# SpaceTrace Product Requirements Document

> 让你在十秒内回答：过去一段时间，什么让 Mac 的可用空间减少了？

| Field | Value |
|---|---|
| Document status | Draft for engineering review |
| Version | 0.2.0 |
| Last updated | 2026-08-14 |
| Product owner | TBD |
| Engineering owner | TBD |
| Target | Public Beta by the end of Week 8 (Assumption) |
| License | TBD — the owner rejected MIT on 2026-08-14; no replacement license is approved |
| Platforms | macOS 15.6 or later on Apple Silicon. The deployment floor is accepted in ADR-001; Public Beta still requires runtime qualification on macOS 15.6 and the current stable macOS. Intel is unsupported until separately qualified. |
| Related roadmap | [Product Roadmap](./product-roadmap.md) |
| Research baseline | [macOS Opportunity Research 2026](../research/macos-opportunity-research-2026.md) |

This document is the source of truth for product scope and acceptance. Architecture documents may choose implementation details, but they must not weaken the user-visible behavior, privacy guarantees, or release gates defined here. Items explicitly labeled **Assumption** require stakeholder confirmation; items labeled **TBD** cannot be treated as committed.

## 1. Executive Summary

### Problem Statement

Mac users frequently discover that tens or hundreds of gigabytes have disappeared into files presented broadly as “System Data.” Existing disk analyzers are effective at showing the current state, but they rarely explain **what grew, when it grew, why it is likely to exist, and what can be inspected safely**. A one-time cleanup also does not explain why the same storage returns days later.

This problem is especially acute for people using 256–512 GB Macs with high-churn workflows such as Xcode simulators, Docker/VM images, AI model caches, Adobe/Final Cut render caches, application logs, cloud downloads, and local APFS snapshots.

Evidence for the opportunity includes recurring 2026 reports of very large or rapidly regrowing System Data ([large System Data report](https://www.reddit.com/r/MacOS/comments/1tg3dfu/system_data_size_is_huge/), [regrowth after cleanup](https://www.reddit.com/r/MacOS/comments/1rj6xp9/system_data_is_expanded_to_over_half_of_storage/)) and explicit requests to track storage over time ([user request](https://www.reddit.com/r/AskTechnology/comments/vsw9ye/i_need_an_app_for_macos_that_keeps_tracks_of/)). Mature tools such as [DaisyDisk](https://daisydiskapp.com/), [GrandPerspective](https://grandperspective.org/), and [Mole](https://github.com/tw93/mole) validate demand for storage visibility, while leaving room for a product centered on longitudinal attribution rather than cleanup.

These sources are exploratory signals, not representative prevalence data. They justify validation and prototyping, not claims about the percentage of all Mac users affected.

### Proposed Solution

SpaceTrace is a native, local-first macOS menu bar application that records low-overhead storage summaries over time. When free space changes, it presents a timeline of the largest growth sources with path evidence, category, time range, size semantics, confidence, permission coverage, and safe next actions.

The first release is an **explanation tool, not a cleaner**:

- It observes user-authorized locations and optional extended locations granted through Full Disk Access.
- It combines filesystem change signals with bounded reconciliation scans so missed or coalesced events can be corrected.
- It uses deterministic, auditable path rules and application metadata; unknown data remains explicitly unknown.
- It never automatically deletes data, terminates processes, modifies system databases, or claims exact equivalence with Apple’s System Data number.
- It keeps all observations on-device, requires no account, sends no telemetry, and exports data only after an explicit user action.

### Product Principles

1. **Explain before acting.** Every conclusion exposes its path, measurement interval, size basis, and confidence.
2. **Read-only by default and by design.** A storage diagnosis must not create a data-loss risk.
3. **Honest uncertainty.** SpaceTrace reports unreadable areas, unknown categories, event gaps, clones, placeholders, snapshots, and purgeable-space ambiguity rather than hiding them.
4. **Local-first trust.** No account, cloud backend, advertising SDK, or silent analytics.
5. **Low overhead.** The observer must not become the storage, CPU, or battery problem it diagnoses.
6. **Small, testable scope.** Beta proves that longitudinal change attribution is useful before adding remediation or broad system-health modules.

### Success Criteria

| ID | KPI | Public Beta target | Measurement without telemetry |
|---|---|---:|---|
| KPI-01 | Explanation task success | At least 80% of evaluators correctly identify the largest known growth source and its time interval within 30 seconds, across at least 12 moderated sessions | Researcher-administered task script; anonymous aggregate results published manually |
| KPI-02 | Large-change detection recall | At least 95% of controlled changes of 5 GB or more appear in the correct watched subtree after reconciliation | Repeatable local benchmark fixtures on the supported OS matrix |
| KPI-03 | Known-category precision | At least 95% precision across a versioned corpus of at least 60 known-path scenarios; no forced label for unknown paths | Open, reviewable classifier fixture suite in the repository |
| KPI-04 | Continuous-observer overhead | In the reference no-change workload: average CPU below 0.5%, p95 CPU below 2%, p95 resident memory below 150 MB, and local database below 250 MB after a simulated 30-day retention period | Reproducible Instruments/XCTest performance protocol; results attached to each release candidate |
| KPI-05 | Privacy integrity | Zero unsolicited outbound connections and zero destructive filesystem operations in release builds | Automated network-deny integration test, binary dependency review, and security checklist |
| KPI-06 | Reliability | Zero open Sev-0/Sev-1 defects; all crash/restart, sleep/wake, event-gap, and database-recovery acceptance tests pass | CI plus opt-in, user-initiated support bundle and GitHub issue reports |

KPI thresholds are initial targets (**Assumption**) and must be validated during Prototype. A threshold may change only through a documented product/architecture decision that explains why the original measurement was invalid or impractical; it may not be silently weakened to pass a release.

## 2. User Experience & Functionality

### User Personas

#### Persona A — Storage-constrained developer (primary)

- Uses a 256–512 GB Apple Silicon Mac for Xcode, Docker, package managers, local databases, or AI models.
- Notices sudden space loss after builds, simulator updates, image pulls, or model downloads.
- Can understand paths and application names but does not want to memorize cache locations or unsafe shell commands.
- Needs evidence before deleting anything that could break an environment.

#### Persona B — Creative professional (primary)

- Uses Adobe applications, Final Cut Pro, DaVinci Resolve, Blender, or similar tools.
- Produces render caches, proxies, preview files, autosaves, and application support data.
- Experiences interrupted exports or updates when free space unexpectedly becomes low.
- Needs an explanation in application-oriented language, with a direct route to the owning application or Finder.

#### Persona C — Privacy-conscious power user (primary)

- Uses cloud storage, Time Machine, external disks, and many locally installed applications.
- Wants to understand APFS snapshots, local downloads, and application data without uploading a filesystem inventory.
- Is willing to grant additional access only when the benefit and blind spots are clearly explained.

#### Persona D — Contributor or support maintainer (secondary)

- Reproduces a classification or measurement issue using sanitized evidence.
- Needs versioned rules, deterministic fixtures, and a support bundle that omits personal filenames by default.
- Reviews product claims against observable evidence rather than opaque AI output.

### End-to-End User Journey

| Stage | User intent | Required experience | Failure-safe behavior |
|---|---|---|---|
| Discover | Decide whether SpaceTrace is trustworthy | README/product page states “tracks change, does not clean”; license and privacy model are visible before install | No claim that SpaceTrace reproduces System Data exactly |
| Install | Launch a verifiable app | App opens on macOS 15.6 or later on the qualified Apple Silicon matrix; signing/notarization status is clearly stated | Older macOS and Intel must not be presented as supported; the accepted ad-hoc Public Beta requires a per-app trust warning, while Developer ID remains required for stable |
| Onboard | Start useful observation with minimal access | User sees what will be scanned, what remains invisible, expected initial-scan cost, retention, and local-only guarantee | Declining Full Disk Access still permits user-selected folder monitoring |
| Baseline | Establish a comparison point | Progress and current coverage are visible; user can pause or quit; partial results are labeled partial | Interrupted baseline resumes or restarts safely without corrupting previous data |
| Observe | Continue normal work | Menu bar shows current free space and 24-hour change; observer remains quiet when no meaningful change occurs | Event gaps, unmounted volumes, and permission revocation create visible health states, not fabricated continuity |
| Investigate | Answer “what grew?” | User opens 24h/7d history, sees ranked growth sources, category, path, confidence, size basis, and timestamps | Unknown/unreadable sources are shown separately; estimates are not presented as exact facts |
| Act safely | Inspect or remediate using trusted tools | User can reveal a path, open the likely owning app, copy a sanitized explanation, or consult a documented manual action | No auto-delete, background cleanup, process termination, or system-database modification |
| Share/support | Report an issue or ask for help | User previews and explicitly exports a redacted diagnostic bundle | Personal names and full paths are removed by default; raw path export requires separate confirmation |
| Upgrade | Keep historical continuity | Schema migration is transactional and preserves or rolls back the existing database | On migration failure, the app runs read-only or restores the previous database; it never discards history silently |

### User Stories and Acceptance Criteria

#### P0 — Required for Public Beta

##### FR-001 — Trust-first onboarding

**Story:** As a privacy-conscious user, I want to know exactly what SpaceTrace reads and stores so that I can make an informed permission decision.

**Acceptance criteria:**

- First launch explains the product purpose, local storage location, default retention, absence of accounts/telemetry, and read-only boundary before any scan begins.
- The user can choose one or more folders with the macOS folder picker and start without Full Disk Access.
- Full Disk Access is presented as an optional coverage enhancement; the UI names examples of locations that may remain inaccessible without it.
- A “Not now” path produces a functional limited-coverage experience and never loops the user back into a permission prompt.
- Permission and coverage state remains accessible from Settings after onboarding.

##### FR-002 — Baseline scan and visible coverage

**Story:** As a new user, I want SpaceTrace to establish a trustworthy baseline so that later changes have a valid comparison point.

**Acceptance criteria:**

- A baseline records total, available, and capacity values for the startup data volume plus summaries for user-authorized roots.
- The UI displays scan state, elapsed time, completed roots, unreadable roots, and cancellation control.
- Canceling or quitting produces either a labeled partial baseline or no committed baseline; it never marks partial data complete.
- Symlinks, aliases, packages, and mount boundaries follow a documented traversal policy and cannot create an infinite loop.
- The committed baseline records its timestamp, app/schema version, watched roots, coverage state, and size semantics.

##### FR-003 — Continuous change observation

**Story:** As a user doing normal work, I want storage changes recorded in the background so that I do not need to remember to run a scan before the problem occurs.

**Acceptance criteria:**

- The observer subscribes only to configured local roots and persists its event cursor/checkpoint across normal restarts.
- Event bursts are coalesced into bounded work units; individual filesystem events are not permanently indexed unless required for reconciliation.
- Sleep/wake, logout/login, and app restart do not create a false zero-change interval.
- An FSEvents gap, dropped-event signal, or invalid cursor marks the interval as incomplete and schedules reconciliation.
- Pausing observation stops new scanning work and is visible in both the menu bar and main window.

##### FR-004 — Bounded reconciliation

**Story:** As a user, I want missed or coalesced filesystem events corrected so that the history remains credible.

**Acceptance criteria:**

- A reconciliation scan compares current summaries with the latest valid checkpoint for affected roots.
- Reconciliation can correct earlier provisional deltas without deleting the original audit metadata.
- Work is bounded by configurable internal budgets for concurrency, I/O, and time slice; the foreground remains responsive.
- The app exposes the last successful reconciliation time and any roots still pending.
- A fixture with a simulated event gap followed by a 5 GB change satisfies KPI-02 after reconciliation.

##### FR-005 — Free-space history and time windows

**Story:** As a user, I want to compare current storage with recent history so that I can locate when a loss began.

**Acceptance criteria:**

- The main view supports at least the last 24 hours and 7 days.
- Each time point distinguishes observed free space, summarized visible data, and unavailable/unknown coverage.
- Clock or timezone changes do not reorder stored observations; persistence uses a monotonic sequence and UTC timestamps while the UI uses the selected locale.
- A discontinuity caused by app pause, unmounted volume, permission loss, or data retention appears as a gap rather than an interpolated line.
- Values use consistent binary or decimal units within a view and identify the chosen convention.

##### FR-006 — Ranked growth sources

**Story:** As a user who lost space, I want the largest growth sources ranked so that I can investigate the likely cause first.

**Acceptance criteria:**

- For each supported time window, SpaceTrace displays at least the top 10 positive-growth sources where data is available.
- Each result includes display name, canonical or redacted path, measured delta, first observed time, last observed time, size basis, and coverage status.
- Parent and child deltas are not double-counted in a single ranked total.
- Deleted or moved sources are represented as decreases or moves when determinable; they are not mislabeled as current growth.
- Ties use a stable, documented sort order.

##### FR-007 — Explainable classification

**Story:** As a user, I want a growth source translated into an understandable category so that I can judge what it may be.

**Acceptance criteria:**

- Beta supports rules for at least: Xcode/Simulator, Docker or local VM storage, AI models/caches, creative-app caches/render data, games, logs/caches, iCloud/local cloud downloads where observable, and local APFS/Time Machine snapshot factors where observable.
- Every classification has a stable rule identifier, rule version, confidence level, and evidence string.
- A result that matches no sufficiently precise rule is labeled “Unknown”; there is no fallback that invents application ownership.
- Rule ordering and conflict resolution are deterministic and covered by fixtures.
- The versioned fixture corpus satisfies KPI-03 before Beta release.

##### FR-008 — Measurement semantics and uncertainty

**Story:** As a technical user, I want SpaceTrace to explain what its numbers mean so that I do not mistake logical size for reclaimable physical space.

**Acceptance criteria:**

- Result details state whether the value is logical size, allocated size, volume free-space change, snapshot-related observation, or an estimate.
- APFS clones/hard links, sparse files, purgeable space, File Provider placeholders, and inaccessible roots display a relevant limitation when encountered or suspected.
- SpaceTrace never labels a byte count “Apple System Data” and never asserts that all observed growth is reclaimable.
- Aggregate views identify when visible subtree deltas do not reconcile with volume free-space deltas.
- Estimated values are visually and programmatically distinguishable from measured values.

##### FR-009 — Menu bar status

**Story:** As a returning user, I want a lightweight status in the menu bar so that I can notice a meaningful storage change without opening the main window.

**Acceptance criteria:**

- The menu bar item can show current available space and the observed 24-hour change.
- It has distinct accessible states for healthy, scanning, paused, limited coverage, attention required, and unavailable.
- Opening the menu reveals last observation time, last reconciliation time, and a control to open the investigation view.
- The status never displays a 24-hour comparison when the baseline/window is incomplete without an uncertainty indicator.
- The menu item works with VoiceOver and keyboard navigation.

##### FR-010 — Safe next actions

**Story:** As a user who understands the likely source, I want a safe route to inspect it so that I can decide what to do without SpaceTrace modifying my data.

**Acceptance criteria:**

- A result can be revealed in Finder when the path still exists and permission allows it.
- Where a verified owning application or System Settings destination is known, SpaceTrace can open it using a documented allowlist.
- Every action names what will happen before execution and reports failure without retry loops.
- Beta contains no automatic delete, bulk delete, process kill, cache purge, snapshot deletion, shell-script execution, or TCC/system-database modification path.
- The product records no claim that revealing or opening an application will free a specific amount of space.

##### FR-011 — Permission and blind-spot handling

**Story:** As a user with limited permissions, I want to know what SpaceTrace cannot see so that I do not trust an incomplete diagnosis.

**Acceptance criteria:**

- Each watched root has a state of covered, partially covered, denied, unavailable, or pending.
- Permission revocation is detected no later than the next attempted observation and does not trigger repeated system prompts.
- The explanation view separates unreadable/unknown volume change from attributed visible growth.
- The app gives a direct, current path to permission guidance but does not manipulate the TCC database.
- Granting or revoking access does not erase previously collected history; historical records retain their original coverage metadata.

##### FR-012 — Local history, retention, and reset

**Story:** As a user, I want predictable local retention controls so that SpaceTrace does not become a storage problem.

**Acceptance criteria:**

- Default retention is 30 days (**Assumption**) and is visible in Settings.
- Retention removes expired detailed summaries transactionally while preserving the minimum aggregate metadata needed to explain gaps.
- The app displays the current database size and estimated effect of the selected retention policy.
- “Reset history” requires explicit confirmation, states that it cannot be undone, and does not delete any monitored user file.
- The default 30-day benchmark satisfies the database-size target in KPI-04.

##### FR-013 — Resilience and database recovery

**Story:** As a user, I want history to survive crashes and upgrades so that a diagnostic tool does not lose its own evidence silently.

**Acceptance criteria:**

- Writes use transactional boundaries; a forced termination during every migration/commit test leaves either the old or new valid state.
- On detected corruption, the app preserves the original database, enters a degraded read-only/rebuild flow, and explains the consequences.
- Schema migrations have forward migration tests and a documented rollback/recovery strategy.
- Running out of disk space stops nonessential writes, surfaces an alert, and never enters an unbounded retry loop.
- App-generated data is excluded from its own growth ranking or explicitly categorized so it cannot create recursive false attribution.

##### FR-014 — Privacy-preserving diagnostic export

**Story:** As a contributor or beta tester, I want to share useful diagnostics without exposing personal filenames by default.

**Acceptance criteria:**

- Export is always user initiated and shows a preview of included sections before writing a file.
- Default export replaces the home-directory username and path components below recognized private roots with stable, nonreversible tokens.
- The bundle includes app/OS version, architecture, coverage state, rule versions, health events, and selected redacted findings; it excludes file contents.
- Including raw paths requires a separate, explicit confirmation for each export.
- No export is uploaded automatically; the user chooses where to save and how to share it.

##### FR-015 — Settings, pause, and uninstall transparency

**Story:** As a user, I want control over background behavior so that the tool remains predictable.

**Acceptance criteria:**

- Settings expose watched roots, observation state, retention, launch-at-login state, database size, and privacy/permission state.
- Launch at login is opt-in during Beta (**Assumption**) and can be disabled in one step.
- Quit stops all SpaceTrace-owned background observation within 10 seconds.
- Documentation identifies all application support locations and explains how to remove SpaceTrace data.
- No helper, launch agent, or privileged component remains after the documented uninstall sequence.

##### FR-016 — Accessible, localized-ready interface

**Story:** As a user relying on macOS accessibility settings, I want every diagnosis and control to be operable without relying on color or pointer input.

**Acceptance criteria:**

- All P0 flows are operable with keyboard navigation and VoiceOver on every supported OS major.
- State and confidence are conveyed by text/symbol labels in addition to color.
- Text supports Dynamic Type-equivalent macOS accessibility sizes without clipping essential values.
- Reduce Motion and Increase Contrast preferences are respected.
- Source strings are externalized for future localization; Beta language set is TBD.

#### P1 — Candidate for 1.0 After Beta Validation

##### FR-101 — Configurable storage-change alerts

**Story:** As a user, I want an alert after a material drop so that I can investigate before the disk becomes critically full.

**Acceptance criteria:**

- User explicitly enables notifications and chooses an absolute and/or percentage threshold.
- Notification deduplication prevents more than one alert for the same unresolved interval within 24 hours.
- The alert opens the exact investigation time window and states if coverage is incomplete.
- Notification text never names a private path on the lock screen by default.

##### FR-102 — Custom watch and exclusion rules

**Story:** As a power user, I want to include or exclude specific roots so that monitoring matches my workflow and privacy needs.

**Acceptance criteria:**

- User-selected includes/excludes are validated for overlap, symlink traversal, and mount boundaries.
- The UI previews the effect on coverage before saving.
- Changing a rule creates a new coverage epoch; historical results preserve the old rule context.
- Invalid or inaccessible rules cannot crash or stall the observer.

##### FR-103 — External local volume support

**Story:** As a creative professional, I want selected external APFS/HFS+ volumes tracked so that project and cache growth is visible beyond the internal disk.

**Acceptance criteria:**

- Support is limited to explicitly selected, directly attached local volumes; network volumes remain out of scope unless separately approved.
- Disconnect/reconnect produces a gap and volume identity is not inferred from display name alone.
- Eject is never blocked by SpaceTrace longer than the current bounded read operation.
- Unsupported filesystems show an explicit compatibility message.

##### FR-104 — Community classification rule packs

**Story:** As an open-source contributor, I want to add deterministic application classifications so that SpaceTrace recognizes more workflows without changing the core engine.

**Acceptance criteria:**

- The rule schema is versioned, documented, and validated before load.
- Rules cannot execute code, shell commands, network requests, or destructive actions.
- Every contributed rule includes positive, negative, and conflict fixtures.
- Invalid third-party rules are quarantined without preventing core rules from loading.

##### FR-105 — Custom comparison ranges and baseline markers

**Story:** As a user troubleshooting an update or project, I want to mark a baseline and compare an arbitrary range so that the result aligns with a known event.

**Acceptance criteria:**

- User can create a named local marker without modifying filesystem data outside SpaceTrace storage.
- A comparison range validates coverage and clearly displays incomplete intervals.
- Exports include the selected range and marker name only after user confirmation.

#### P2 — Future Exploration, Not Committed

##### FR-201 — Guided remediation catalog

**Story:** As a user, I want application-specific cleanup guidance so that I can use the owning application’s supported controls.

**Acceptance criteria:**

- Any guidance is versioned, source-linked, reversible where possible, and reviewed for the supported app version.
- SpaceTrace does not execute deletion in this scope.
- Stale or unverifiable guidance is hidden rather than guessed.

##### FR-202 — Trend and recurrence insights

**Story:** As a user, I want to know whether a source repeatedly regrows so that I can change the underlying workflow.

**Acceptance criteria:**

- Insights use only local historical observations and expose the intervals used.
- A recurrence claim requires at least three completed comparable intervals (**Assumption**).
- No forecast is presented as guaranteed reclaimable capacity.

##### FR-203 — Intel Mac support

**Story:** As an Intel Mac user, I want SpaceTrace to run on my supported hardware so that I can investigate the same storage issues.

**Acceptance criteria:**

- Commitment depends on maintainer capacity and a real-device compatibility matrix; status is TBD.
- Intel support cannot reduce Apple Silicon performance/reliability gates or delay the eight-week Beta target without explicit approval.

### Non-Goals

The following are not part of Public Beta or 1.0 unless a later PRD changes the boundary:

- Reproduce or replace Apple’s System Data calculation exactly.
- Act as a general-purpose disk visualizer, antivirus, optimizer, uninstaller, or “Mac cleaner.”
- Automatically delete files, caches, snapshots, backups, containers, simulators, models, or application data.
- Terminate processes, unload services, modify TCC/SIP settings, or write to private system databases.
- Attribute a write to an exact process solely from FSEvents; process-level attribution requires separate validated research.
- Upload path inventories, usage data, crash logs, or diagnostics without an explicit per-export user action.
- Require an account, subscription backend, or cloud synchronization.
- Monitor file contents or retain a permanent per-file activity log.
- Promise that an identified byte count is safe or fully reclaimable.
- Support network/NAS volumes in Beta.
- Guarantee Intel compatibility, Mac App Store distribution, automatic updates, Developer ID signing, or notarization until the relevant release decision is approved.
- Bundle Backup Canary, CloudGuard Dev, window management, audio control, external-display control, or other unrelated utility modules.

## 3. AI System Requirements (Not Applicable)

SpaceTrace Beta does not use machine learning, generative AI, remote inference, embeddings, or opaque heuristic ownership prediction. Classification is deterministic and reviewable. This is a deliberate product requirement, not an implementation omission.

### Tool Requirements

- The classifier consumes normalized path features, bundle/application metadata, volume context, and versioned rules.
- Rule evaluation must work completely offline and produce a rule ID, version, confidence tier, and evidence.
- Unknown or conflicting cases must remain unknown/ambiguous.
- A future AI feature requires a separate PRD, explicit privacy threat model, offline-vs-cloud decision, evaluation corpus, opt-in design, and failure/fallback behavior.

### Evaluation Strategy

- Maintain a versioned fixture corpus with representative positive, negative, ambiguous, renamed-home, cloud-placeholder, and nested-rule cases.
- Report precision by category and overall; do not use accuracy alone when unknown cases dominate.
- Public Beta gate: overall known-category precision at least 95%, at least 90% precision per P0 category with ten or more fixtures, and 100% correct “unknown” behavior for the designated ambiguity suite.
- Any rule regression blocks release until fixed or the rule is disabled with a documented rationale.

## 4. Technical Specifications

### Architecture Overview

The PRD requires the following logical data flow; detailed component boundaries and technology decisions belong in the architecture documentation.

```text
User-approved roots and local volume metadata
        │
        ├── bounded baseline/reconciliation scan
        └── filesystem change observer
                    │
                    ▼
          normalized change candidates
                    │
                    ▼
       size summarizer + coverage evaluator
                    │
                    ▼
        transactional local history store
                    │
                    ├── deterministic classifier/rule evidence
                    ├── timeline and top-growth query model
                    └── user-initiated redacted export
```

Required architectural properties:

- Native Swift/SwiftUI with targeted AppKit integration (**Assumption**).
- The checked-in Xcode Project, App, Unit Tests, and UI Tests configurations use `MACOSX_DEPLOYMENT_TARGET = 15.6` (**accepted repository and product baseline as of 2026-07-18**). Public Beta still requires P0 API, automated-test, lifecycle, permission, and user-journey qualification on a physical or virtual macOS 15.6 environment. This support claim does not include Intel or macOS 14.
- Event-driven observation plus periodic/triggered reconciliation; FSEvents cannot be treated as a process-audit log.
- Transactional, versioned, local persistence; SQLite is the preferred baseline (**Assumption**) subject to architecture review.
- No privileged helper for Beta unless a separate security decision proves it necessary; current product scope does not require destructive or privileged actions.
- Components for observation, traversal, measurement, classification, persistence, query, presentation, and export must be independently testable.
- All system-command integrations, if any, use fixed executable paths, typed arguments, bounded timeouts, captured exit status, and no shell interpolation.

### Canonical Product Data

At minimum, the product model must preserve:

| Entity | Required fields |
|---|---|
| Volume | Stable identity where available, filesystem type, capacity, available space, mount state, observation timestamp |
| Watched root | Security-scoped identity/bookmark where applicable, path display policy, coverage state, traversal policy, configuration epoch |
| Observation/checkpoint | UTC time, monotonic sequence, app/schema version, source, completeness, event cursor, error/health state |
| Directory summary | Root, normalized relative identity, logical/allocated size where available, file/directory counts where budget permits, measurement semantics |
| Delta | Comparison endpoints, measured increase/decrease, completeness, parent/child aggregation policy |
| Classification | Category, rule ID/version, confidence tier, evidence, conflict/unknown state |
| Health event | Permission loss, event gap, mount change, scan cancellation, corruption/recovery, disk-full condition |

The store must not persist file contents. Permanent storage of every raw filesystem event is not required and is discouraged.

### Integration Points

| Integration | Purpose | Product constraint |
|---|---|---|
| FSEvents | Identify changed subtrees | Events may be coalesced/dropped and do not prove process ownership; reconciliation is mandatory |
| FileManager / URL resource values | Enumerate and measure accessible files/directories | Race-safe handling is required because entries may change during enumeration |
| Disk/volume APIs | Track capacity, availability, mount state, and stable identity | Display name alone is not a stable volume identity |
| AppKit/SwiftUI | Menu bar, settings, timeline, accessible UI | P0 flows must support keyboard and VoiceOver |
| Security-scoped access / TCC | Persist user-approved access and detect limits | Full Disk Access is optional; never modify TCC data directly |
| Local database | Persist history, schema, health, and classifications | Transactional migration, bounded retention, and corruption recovery required |
| Finder/System Settings/application URLs | Safe inspection actions | Allowlisted destinations only; no destructive command execution |
| User-selected file export | Write redacted diagnostic bundle | Preview and explicit action required; no automatic upload |

Authentication is not applicable because SpaceTrace has no account or remote service. If automatic updates are selected later, update signing and transport become separate security-sensitive integration points. Update mechanism is TBD.

### Security & Privacy

#### Data handling

- All observations, classifications, settings, and history remain on the Mac.
- No telemetry, analytics SDK, advertising SDK, remote crash reporter, account identifier, or background network request is permitted in Beta.
- No file contents are inspected for classification; only metadata needed for storage measurement and explainable rules may be used.
- Filenames and paths are sensitive. UI reveals them locally, but default diagnostic export redacts private components.
- Data retention is bounded and user-configurable; reset affects SpaceTrace data only.

#### Threat model minimums

- Malicious or malformed filesystem names must not produce command injection, path traversal outside authorized roots, UI spoofing, or export escaping.
- Symlink/hard-link/clone structures must not cause traversal loops or double-counting that is presented as precise.
- Untrusted community rules, if introduced, are declarative data and cannot execute code.
- Database corruption or crafted local records must fail closed without destructive recovery.
- Permission denial is a normal state, not an error to bypass.
- A diagnostic archive must not include raw paths or file contents unless the user explicitly opts in after preview.

#### Distribution security

- MIT was explicitly rejected by the owner on 2026-08-14. A different project license remains **TBD** and must be approved and reflected consistently in repository metadata, notices, SPDX, and the release qualification before Beta.
- The owner accepted an ad-hoc-signed, unnotarized Public Beta distribution policy on 2026-08-14. The release page must disclose that macOS cannot verify the publisher, provide checksums/provenance and exact per-app **Open Anyway** steps, disable automatic updates, and never describe the artifact as stable, notarized, or Apple-verified. Developer ID signing/notarization remains required for a future stable direct-distribution release.
- Every published artifact requires a reproducible version, commit reference, checksum, and documented provenance.
- App Store distribution is not committed.

### Non-Functional Requirements

##### NFR-001 — Background CPU

- In a 30-minute no-change reference workload after baseline, average process CPU must be below 0.5% and p95 below 2% on the reference Apple Silicon Mac.
- Measurement protocol and hardware details are checked into the repository; results are attached to the release candidate.

##### NFR-002 — Memory and local storage

- p95 resident memory must remain below 150 MB in the 30-day benchmark dataset.
- Default-retention database size must remain below 250 MB for the benchmark workload.
- Any threshold revision requires a benchmark-backed decision record.

##### NFR-003 — Responsiveness

- Warm launch to interactive menu bar state must complete within 2 seconds at p95 on the reference device.
- A 7-day top-100 growth query over the benchmark store must complete within 500 ms at p95.
- Scan work must not block the main actor for more than 100 ms in instrumentation tests.

##### NFR-004 — Bounded resource use

- Baseline and reconciliation concurrency must be bounded and cancellable.
- No retry path may run without exponential backoff and a terminal/visible failure state.
- Prototype must establish a realistic baseline-scan target for 500,000 and 1,000,000 entries; exact duration is TBD until measured.

##### NFR-005 — Reliability and integrity

- All supported sleep/wake, restart, force-quit, event-gap, disk-full, and migration fixtures pass.
- The database never silently resets after corruption or migration failure.
- The app never holds a removable volume open beyond a bounded active read.

##### NFR-006 — Privacy/network isolation

- Release builds initiate zero outbound network connections during onboarding, baseline, observation, investigation, export, and quit tests.
- CI fails if a new dependency adds network or telemetry capability without an approved decision record and PRD update.

##### NFR-007 — Accessibility

- All P0 journeys pass a documented keyboard-only and VoiceOver manual test on macOS 15.6 and the then-current stable macOS on Apple Silicon.
- Automated accessibility identifier/label tests cover all interactive P0 elements.

##### NFR-008 — Compatibility

- Current repository fact and accepted decision: all Project/App/Unit Tests/UI Tests configurations use deployment target macOS 15.6 as of 2026-07-18; Apple Silicon is the initial supported architecture.
- A clean build on a newer host is necessary but not sufficient. Before Public Beta, macOS 15.6 must pass the P0 API audit, automated tests that can run on that OS, and the documented manual lifecycle/permission/accessibility matrix.
- Public Beta supports only the matrix actually built and qualified, spanning the approved minimum through the then-current stable macOS release. Latest patch versions are the release-gate baseline; no untested older major may be advertised as supported.
- Intel and prerelease macOS versions are explicitly unsupported until separately qualified.

##### NFR-009 — Maintainability

- Observation, measurement, classification, persistence, and presentation layers have test seams and no mandatory UI dependency.
- Core rule and measurement logic achieves at least 80% line coverage and 100% branch coverage for destructive-action guards (**Assumption**).
- Every schema and rule change carries migration/fixture documentation in the same pull request.

##### NFR-010 — Auditability

- Every user-visible attribution can be traced to observation endpoints, normalized path identity, rule ID/version, and size semantics.
- Support exports include enough redacted evidence to reproduce classification decisions without file contents.

### Boundary and Failure Scenarios

| Scenario | Required behavior |
|---|---|
| Full Disk Access denied/revoked | Continue with authorized roots; mark blind spots and start a new coverage epoch |
| Directory changes during enumeration | Handle not-found/permission errors per entry; do not fail the entire scan or reuse stale metadata as current |
| FSEvents coalesced/dropped/cursor invalid | Mark interval incomplete, schedule bounded reconciliation, never infer exact write sequence |
| App sleeps, Mac sleeps, or clock changes | Preserve UTC/monotonic ordering; show observation gap until reconciliation |
| Volume unmounted/renamed/replaced | Track stable identity where possible; never attach old history using display name alone |
| File Provider placeholder or cloud-only file | Label size semantics/availability; do not force download merely to measure it |
| APFS clone, hard link, sparse file | Avoid known double counts and disclose ambiguity; distinguish logical from allocated size where available |
| Purgeable space or local snapshot changes | Present as a separate volume/snapshot factor when observable, never as guaranteed reclaimable bytes |
| Symlink loop or path escapes selected root | Do not follow outside documented policy; record a bounded warning |
| Massive event burst | Coalesce and backpressure; UI stays responsive; eventually reconcile |
| Database corrupted | Preserve original, enter recovery/degraded mode, no silent history deletion |
| Disk becomes critically full | Stop optional history writes/scans, keep UI responsive, communicate that current data may be incomplete |
| SpaceTrace database grows | Exclude or clearly classify its own storage so it cannot recursively blame monitored applications |
| Rule conflict | Show ambiguous/unknown with evidence; deterministic resolution only for explicitly ordered compatible rules |
| Export interrupted | Leave no misleading “complete” archive; clean up temporary material safely on next launch |
| No valid baseline | Show current state only and explain that change attribution begins after a completed baseline |

### Dependencies

- Access to Apple Silicon Macs representing 256 GB and 512 GB storage classes for performance and low-disk testing.
- Access to a physical or virtual macOS 15.6 Apple Silicon environment plus a real Apple Silicon device on the current stable macOS. Before Beta, the complete P0 lifecycle must pass on 15.6, and at least one real-device run must pass on the current stable release.
- Real fixtures or safely generated equivalents for Xcode/Simulator, Docker/VM, AI model cache, creative cache, game data, cloud placeholders, logs, and snapshots.
- Maintainer access to Apple Developer Program credentials is **TBD** and required only if Developer ID signing/notarization is chosen.
- Architecture decisions for persistence library, update channel, login item mechanism, rule format, and snapshot integration are TBD.
- Product/design review for onboarding, uncertainty language, accessibility, and diagnostic redaction.
- Documentation for install, permissions, measurement semantics, privacy, troubleshooting, contribution, classification rules, and removal before public Beta.

## 5. Risks & Roadmap

### Phased Rollout

The detailed phase plan, entry/exit criteria, and non-commitments are maintained in [product-roadmap.md](./product-roadmap.md). The current rollout assumption is:

| Phase | Target window | Outcome |
|---|---|---|
| Discovery | Week 1 | Validated problem, scope, benchmark protocol, and technical unknowns |
| Prototype | Week 2 | Measured vertical slice proving observation → reconciliation → explanation |
| Alpha | Weeks 3–5 | Feature-complete internal P0 implementation with migration/privacy foundations |
| Beta | Weeks 6–8 | Closed qualification followed by Public Beta no later than end of Week 8 |
| 1.0 | TBD, after Beta evidence | Stable release only when Beta exit gates and distribution decision are satisfied |

The eight-week target means **Public Beta by the end of Week 8** (**Assumption**); it does not commit a 1.0 date or an eight-week Beta duration.

### Release Gates

Public Beta may ship only when all of the following are true:

1. ADR-001 remains accepted; all Project/App/Unit Tests/UI Tests configurations resolve to macOS 15.6; all P0 functional requirements and acceptance criteria pass on macOS 15.6 and the current stable macOS on Apple Silicon. Public materials state that macOS 14 and Intel are unsupported.
2. KPI-02 through KPI-06 pass using the checked-in benchmark/evaluation protocol; KPI-01 has at least six formative sessions completed and no repeated blocker, with the final 12-session target allowed to complete during Beta.
3. There are zero open Sev-0 (data loss/security) and Sev-1 (core workflow unusable or materially misleading) defects.
4. Static and dynamic tests confirm no destructive operations and no unsolicited outbound connections.
5. Permission-denied, event-gap, sleep/wake, migration-failure, corruption, critical-disk, clone/hard-link, and cloud-placeholder scenarios have explicit test evidence.
6. Diagnostic export redaction has passed adversarial review using usernames, Unicode/control characters, nested private paths, and raw-path opt-in.
7. Installation/distribution status is unambiguous: signed/notarized artifacts if approved, or clear pre-release warning plus checksums if not.
8. Required user and contributor documentation is current, linked, and tested on a clean Mac user account.
9. License, third-party notices, SBOM/dependency inventory, artifact checksum, version, and source commit are published.

1.0 requires all Public Beta gates plus:

- KPI-01 completed with at least 12 sessions and target met.
- At least four weeks of public Beta observation (**Assumption**) or an explicit decision with equivalent evidence.
- No unresolved repeated Sev-2 issue affecting measurement credibility, database integrity, permissions, or excessive resource use.
- Upgrade/migration from every published Beta schema is tested.
- Developer ID signing/notarization and update-distribution decisions are resolved, documented, and reflected in installation guidance.
- P1 scope is selected based on Beta evidence; no P1 feature is automatically required for 1.0.

### Technical and Product Risks

| Risk | Likelihood | Impact | Mitigation / trigger |
|---|---|---|---|
| Volume free-space change does not reconcile with visible files because of snapshots, clones, purgeable data, or private areas | High | High | Separate semantics and coverage; show residual unknown; never claim exact System Data equivalence |
| FSEvents gaps/coalescing create misleading history | Medium | High | Persist cursor health, mark incomplete intervals, run bounded reconciliation, test gap fixtures |
| Initial/reconciliation scans cause battery, I/O, or thermal impact | Medium | High | Budget work, pause on low power/critical conditions, benchmark before scope expansion |
| Full Disk Access requirement reduces trust/adoption | High | Medium | Useful folder-picker mode first; explain exact benefit/blind spots; no repeated prompts |
| Path classifier mislabels user data as disposable cache | Medium | High | Conservative precision gate, evidence/confidence, “Unknown” fallback, no deletion |
| APFS/File Provider behavior drifts across macOS releases | Medium | High | Public API preference, OS matrix, capability checks, fixture/version gates |
| Local database becomes large or corrupted | Low–Medium | High | Aggregated summaries, retention, transactional migrations, corruption preservation/rebuild |
| No telemetry makes product health difficult to measure | High | Medium | Local scorecard, opt-in export, public benchmark suite, moderated tests, GitHub issue templates |
| Eight-week scope exceeds small-team capacity | Medium | High | P0-only Beta, explicit phase exits, Prototype stop/go gates, no cleaner/alerts/external-volume expansion |
| Unsigned/unnotarized Beta creates installation friction | Medium | Medium–High | Resolve Developer ID decision before Beta gate; if unresolved, disclose and ship checksums only if risk accepted |
| Open-source rules expose sensitive real paths in contributions | Medium | Medium | Synthetic fixtures, contribution template, automated secret/path checks, no raw diagnostics in issues |
| User interprets “growth source” as “safe to delete” | Medium | High | Consistent non-reclaimability language, evidence/semantics, no destructive action UI |

### Privacy-Friendly Measurement Plan

Because SpaceTrace has no telemetry, product decisions use evidence collected through explicit, reviewable channels:

1. **Local benchmark suite:** Generated filesystem scenarios, expected deltas, classification fixtures, event gaps, performance workloads, and migration tests run in CI or by maintainers.
2. **Moderated usability sessions:** Participants perform a scripted low-space investigation; researchers record only task completion, elapsed time, errors, and qualitative comments with consent.
3. **User-controlled Beta scorecard:** The app may display a local health page (observation completeness, reconciliation status, resource use summary, database size). Export is manual and previewable.
4. **Structured GitHub templates:** Issues request app/OS version, category, expected/actual behavior, reproduction, and optional redacted bundle. Templates warn users not to paste personal paths.
5. **Release-candidate evidence pack:** Maintainers publish benchmark versions, hardware/OS matrix, test results, known limitations, and unresolved risks for each release.

No metric justifies adding silent analytics. Any future telemetry proposal requires a separate decision and PRD change; default remains off and local-only.

### Open Decisions and Assumptions

| ID | Item | Current position | Decision deadline |
|---|---|---|---|
| OD-01 | Initial audience | 256–512 GB Mac developers, creative professionals, and power users (Assumption) | End of Discovery |
| OD-02 | Platform qualification | macOS 15.6+ on Apple Silicon is confirmed as the baseline. Runtime P0 qualification on 15.6 remains required; Intel and macOS 14 are unsupported. | Public Beta entry |
| OD-03 | Implementation | Swift/SwiftUI with limited AppKit (Assumption) | Prototype exit |
| OD-04 | License | TBD — MIT rejected by owner on 2026-08-14; replacement not approved | Before Public Beta artifact publication |
| OD-05 | Privacy | Local-first, no account, no telemetry; treated as a hard product constraint | Any change requires new PRD/security review |
| OD-06 | Full Disk Access | Optional enhancement; useful selected-folder mode without it | Alpha exit |
| OD-07 | Retention | 30-day default (Assumption) | Alpha usability/performance review |
| OD-08 | Beta language(s) | TBD | Alpha exit |
| OD-09 | Developer ID signing/notarization | Ad-hoc, unnotarized Public Beta risk accepted on 2026-08-14; Developer ID/notarization remains mandatory for stable | Beta qualification; stable entry |
| OD-10 | Update mechanism | Manual downloads only for the ad-hoc Public Beta; no automatic updater until a separately reviewed signed-update design | Before any automatic update channel |
| OD-11 | 1.0 date | Not committed | After Public Beta evidence |
| OD-12 | Intel support | P2 / TBD | After 1.0 scope review |
