# SpaceTrace Product Roadmap

> Outcome-based delivery plan from validated problem to a trustworthy Public Beta.

| Field | Value |
|---|---|
| Document status | Draft for product and engineering review |
| Version | 0.1.0 |
| Last updated | 2026-08-13 |
| Planning horizon | Eight weeks to Public Beta (Assumption); 1.0 date TBD |
| Platform state | Accepted baseline: macOS 15.6+ on Apple Silicon. All Project/App/Unit Tests/UI Tests configurations are aligned; runtime qualification remains a Public Beta gate. |
| Source of requirements | [Product Requirements Document](./product-requirements.md) |

This roadmap is a sequencing and evidence plan, not a promise that every proposed feature will ship. Product scope and acceptance criteria remain authoritative in the PRD. A phase exits only when its evidence gate passes; reaching a calendar date is not sufficient.

## Current Release Decision — NO-GO retained; evidence refreshed 2026-08-13

**Public Beta and GitHub Release: NO-GO. Local engineering RC generation: CONDITIONAL GO.** No tag, GitHub Release, or artifact upload was created by this decision. The local RC channel exists only to continue controlled qualification with the [ad-hoc release candidate checklist](../engineering/release-candidate-checklist.md).

| Gate | Status | Evidence / remaining condition |
|---|---|---|
| Current-stable-macOS endurance and process-resource evidence | Passed for current-host ad-hoc scope | Corrected 25-hour run and deterministic Instruments analysis are recorded in the [background soak protocol](../engineering/background-soak-qualification.md); this is not watt/joule, Apple-identity, or minimum-OS evidence |
| Current-host controlled UI/accessibility tree | Passed for automated fixture scope | Twelve authorization/history/finding scenarios passed, including current versus invalidated evidence, History Off, baseline unavailable, and destructive confirmation; manual VoiceOver, Full Keyboard Access, contrast/motion/larger-text review remains open in the [visual design system](./visual-design-system.md) |
| Ad-hoc RC artifact contract | Passed | Two independent `0.1.0-rc.1` builds from `f2119be` passed checksums, strict code signing, entitlement, architecture, deployment-target, DMG, and manifest checks; Gatekeeper rejected them as expected |
| Complete P0 product workflow | Open — release blocking | The deterministic classifier and reviewed 64-known/32-Unknown FR-007 corpus, immutable coverage-aware finding projection, schema-v11 persistence, production complete-scan paired finalization, complete-parent disappearance reconciliation, qualified APFS stable moves, projector lifecycle, and finding/History-Off Overview are implemented. Replacement/supersession, true in-enumerator continuation, and user-controlled redacted export remain open |
| macOS 15.6 Apple Silicon runtime | Blocked by unavailable qualified host | Compile/link target is 15.6, but no P0 runtime/benchmark evidence exists on that OS |
| ADR-003, ADR-004, and ADR-006 | Open — release blocking | All remain Proposed. Genuine daemon drop/wrap, permission revocation, minimum-OS behavior, replacement/supersession, manual finding-UI review, and maintainer review remain incomplete; automated finding UI, explicit disappearance, and APFS stable-move evidence pass current-host qualification |
| Developer identity and notarization | Blocked for trusted public distribution | No stable Apple signing identity is installed. Ad-hoc tester risk has documentation but is not equivalent to Developer ID/notarization |
| Fresh quarantined clean-account install | Open — release blocking | DMG verification passed locally; an actual downloaded/quarantined clean-account flow and per-app Gatekeeper exception have not been qualified |
| Update/replacement and bookmark continuity | Partial — release blocking | Fresh/same-build/replacement process launch passed under a disposable ID; no bookmark was created, so cross-build restore/reselection behavior remains open |
| Migration, corruption, and retention | Partial | Deterministic current-schema/golden-fixture recovery and large-row benchmarks passed; packaged upgrade, downgrade, and rollback remain open |
| Permission, stale, denial, and external-volume RC matrix | Partial | Deterministic and earlier sandbox/native rows exist; genuine stale/denial, different-UUID packaged UI, and active-scan revocation remain open |
| License, notices, and SBOM | Blocked — owner decision required | MIT is still an assumption; no approved `LICENSE`, complete third-party notices, or release SBOM is present |
| Usability and severity gates | Open — release blocking | Required formative sessions, KPI review, and release-specific Sev-0/Sev-1 triage record are incomplete |

The next release review may change `NO-GO` only after every release-blocking row has linked, current evidence. A paid signing identity alone is not sufficient because product-completeness, minimum-OS, usability, accessibility, license, and update/rollback gates are independent.

## Planning Rules

1. Public Beta by the end of Week 8 is the current planning assumption. Schedule risk is absorbed by removing non-P0 scope, not by weakening privacy, integrity, or honesty requirements.
2. Work is organized around risk retirement: measurement semantics and overhead first; polish and scope expansion later.
3. “Done” means code, tests, documentation, accessibility, privacy review, migration impact, and observable acceptance evidence are complete in the same change.
4. Any feature that deletes user data, terminates a process, modifies a system database, uploads diagnostics, or depends on an opaque AI decision is out of scope.
5. Developer ID signing/notarization, update delivery, Beta languages, Intel support, and 1.0 date remain TBD until their stated decision points.
6. Discovery can invalidate or materially narrow the plan. A stop or pivot is a valid outcome when the core attribution cannot meet credibility and overhead gates.

## Milestone Summary

| Phase | Calendar target | Primary question | Exit outcome |
|---|---|---|---|
| Discovery | Week 1 | Is longitudinal storage attribution valuable, measurable, and narrow enough? | Approved scope, research evidence, benchmark plan, and risk register |
| Prototype | Week 2 | Can a small native vertical slice observe, reconcile, and explain a real change at acceptable cost? | Go/no-go evidence for architecture and core KPIs |
| Alpha | Weeks 3–5 | Can the complete P0 workflow operate safely across restarts, permissions, and failure cases? | Feature-complete internal build with tested data/privacy foundations |
| Beta | Weeks 6–8 | Can representative users understand and trust the output on the supported OS matrix? | Public Beta by end of Week 8 if all gates pass |
| 1.0 | TBD after Beta | Is SpaceTrace stable, maintainable, distributable, and proven useful? | Stable release with migration and support commitments |

## Phase 1 — Discovery (Week 1)

### Objective

Convert the opportunity research into validated user problems, precise size semantics, and a testable product boundary before committing to implementation.

### Entry Criteria

- SpaceTrace is selected as the preferred opportunity.
- Initial audience and constraints are recorded as assumptions.
- The opportunity research and PRD draft are available to product and engineering.
- At least one maintainer is assigned; owner names may remain TBD only until the phase review.

### Workstreams and Deliverables

#### Product validation

- Conduct at least five problem interviews or structured walkthroughs across developer, creative, and power-user profiles.
- Collect concrete “space disappeared” timelines, tools tried, decisions made, and unsafe/confusing moments.
- Validate whether “what changed and when” is more valuable than another current-state map.
- Define the 30-second explanation task used by KPI-01.

#### Competitive and platform validation

- Refresh competitor review for longitudinal storage tracking, not just disk visualization/cleaning.
- Audit every P0 API against the accepted macOS 15.6 floor: selected-folder access, FSEvents, volume identity, login items, snapshot visibility, permissions, power/thermal state, and SwiftUI/AppKit behavior. Record macOS 14 and Intel as unsupported rather than silently relying on unqualified behavior.
- Document where SpaceTrace can measure logical size, allocated size, free-space change, snapshots, placeholders, clones, and purgeable data.
- Confirm that no P0 workflow requires a privileged helper or private API.

#### Quality planning

- Define benchmark hardware and generated datasets for 256 GB and 512 GB storage profiles.
- Define classification fixture schema and initial P0 category list.
- Establish defect severity, privacy review, accessibility checklist, and release evidence template.
- Decide or assign decision owners for OD-01 through OD-04 in the PRD.

### Exit Criteria

- At least four of five discovery participants recognize the problem and can describe a recent or credible example; this is a directional gate, not prevalence evidence.
- The top user journey and P0/non-goal boundary are approved.
- Measurement semantics document names known blind spots and explicitly rejects exact System Data equivalence.
- Prototype hypotheses, datasets, benchmark protocol, and success/failure thresholds are written.
- Architecture has no known requirement for automatic deletion, privileged modification, account, or telemetry.
- Critical unknowns have named owners and deadlines.

### Stop/Pivot Triggers

- Representative users consistently want one-time cleanup rather than longitudinal explanation.
- A useful selected-folder experience is impossible without mandatory Full Disk Access.
- Public APIs cannot produce a credible delta after reconciliation on supported OS versions.
- A direct maintained competitor already provides the same longitudinal evidence, privacy model, and open-source position with no meaningful differentiation.

### Dependencies

- Research participants or representative internal proxies.
- Apple documentation and real test Macs.
- Opportunity research, PRD, architecture draft, and threat-model collaboration.

## Phase 2 — Prototype (Week 2)

### Objective

Prove the riskiest end-to-end path with real measurements: user-selected root → baseline → filesystem change → event gap/reconciliation → ranked explanation.

### Entry Criteria

- Discovery exit criteria pass.
- Prototype benchmark and expected results are versioned.
- Architecture decision candidates for observer, traversal, persistence, and size semantics are documented.

### Committed Prototype Scope

- Minimal native menu/window shell on Apple Silicon.
- One user-selected root and startup data-volume free-space observation.
- Baseline directory summary with cancel/partial-state behavior.
- FSEvents capture for changed subtrees.
- Forced event-gap test followed by bounded reconciliation.
- Local transactional store with one migration/recovery exercise.
- Deterministic classification of at least Xcode/Simulator and Docker/VM fixtures plus Unknown.
- A single 24-hour/delta explanation view with evidence and size semantics.
- Instrumented CPU, memory, I/O, query latency, and database-growth measurements.

### Exit Criteria

- Controlled 5 GB changes are detected after reconciliation in at least 19 of 20 trials across the prototype matrix.
- Parent/child aggregation does not double-count the benchmark change.
- Unknown fixture paths remain unknown; classifier evidence and rule version are visible.
- Observer meets KPI-04 no-change CPU/memory targets or has a measured, approved correction plan that does not change the Beta date.
- Forced termination cannot produce a silently valid-looking corrupt database.
- Selected-folder mode works without Full Disk Access.
- The macOS 15.6 Apple Silicon baseline has clean Debug/Release builds and unit tests, a completed P0 API audit, and an owned plan for minimum-OS runtime qualification; the team also records decisions for Swift/SwiftUI, persistence, and snapshot scope.

### Stop/Pivot Triggers

- Reconciled deltas remain materially wrong or misleading in common fixtures.
- Baseline/reconciliation cannot be bounded enough for a background utility.
- macOS 15.6 requires incompatible product behavior that cannot be capability-gated without misleading users or missing the Beta scope.
- Credible explanation requires file contents, private APIs, or process-level tracing.

### Dependencies

- Generated large-tree fixtures and real high-churn application directories.
- Access to a physical or virtual macOS 15.6 Apple Silicon environment and a real Apple Silicon device on the current stable macOS before Beta.
- Architecture and security review of subprocess/system integration, if any.

## Phase 3 — Alpha (Weeks 3–5)

### Objective

Build the complete P0 product behind an internal/pre-release channel and make it resilient to permissions, lifecycle, schema, and storage edge cases.

### Entry Criteria

- Prototype go decision is recorded.
- Core architecture and database schema v1 are approved.
- P0 requirements are decomposed into owned engineering work with test plans.
- CI can build and test the minimum supported macOS target.

### Week 3 — Observation and Persistence Foundation

- Implement FR-001 through FR-005: trust onboarding, baseline, continuous observation, reconciliation, and time windows.
- Persist coverage epochs, event/checkpoint health, volume identity, size semantics, and schema version.
- Add sleep/wake, restart, event-gap, mount-change, symlink-loop, and concurrent-mutation fixtures.
- Establish 30-day retention simulation and SpaceTrace self-data exclusion.
- Draft permissions, measurement semantics, and troubleshooting documentation.

### Week 4 — Explanation and Safe Interaction

- Implement FR-006 through FR-011: ranked sources, deterministic classification, uncertainty, menu bar, safe actions, and blind spots.
- **Completed 2026-08-13:** 64 known-path fixtures (eight per P0 category), 32 Unknown near misses, exact rule metadata contracts, and separate ambiguity cases pass the versioned corpus gate.
- Manually qualify the implemented finding/History-Off Overview for keyboard navigation, VoiceOver, contrast, larger text, and uncertainty wording on macOS 15.6 and current stable macOS.
- Run first keyboard/VoiceOver review and uncertainty-language review.
- Conduct three formative usability walkthroughs with current build.

### Week 5 — Resilience, Privacy, and Beta Feature Complete

- Implement FR-012 through FR-016: retention/reset, database recovery, redacted export, settings/lifecycle, and accessibility readiness.
- Exercise migration rollback, corruption preservation, critical-disk behavior, export interruption, and Unicode/control-character redaction.
- Complete dependency inventory, privacy review, threat-model review, and no-network dynamic test.
- Freeze P0 feature scope; new feature requests move to P1/P2 unless they fix a release blocker.
- Resolve Beta language, Full Disk Access positioning, retention default, Developer ID decision owner, and update-mechanism decision owner.

### Alpha Exit Criteria

- Every P0 requirement is implemented behind a releasable UI and has automated or documented manual acceptance evidence.
- Core controlled-change and classifier precision gates pass.
- No known destructive operation exists in the product or bundled scripts.
- No unsolicited network connection occurs in all P0 journeys.
- Database migration/recovery, sleep/wake, permission loss, event gap, mount change, and low-disk tests pass.
- p95 memory, local database, query latency, and observer CPU targets pass on reference hardware.
- All P0 journeys are keyboard operable; no known VoiceOver blocker remains.
- Zero open Sev-0/Sev-1 defects; Sev-2 credibility/performance defects have owners and Beta deadlines.

### Dependencies

- Stable architecture/API interfaces by Week 3.
- Design decisions for timeline, evidence, unknown/partial states, and menu bar status.
- Security review availability in Week 5.
- Documentation review and clean-user-account testing.

## Phase 4 — Beta (Weeks 6–8)

### Objective

Qualify product usefulness and trust with representative users and the full supported OS matrix, then publish a transparent Public Beta by the end of Week 8 only if release gates pass.

### Entry Criteria

- Alpha exit criteria pass.
- P0 scope is frozen except for defect fixes, accessibility fixes, and evidence/wording corrections.
- Distribution plan, versioning, checksums, license notices, and rollback path are documented.
- Developer ID signing/notarization status is decided or explicitly risk-accepted with user-facing disclosure.
- Support issue templates and redacted diagnostic workflow are ready.

### Week 6 — Closed Beta Qualification

- Enroll 8–12 opt-in testers spanning the three primary personas and supported OS majors.
- Run install/onboarding, selected-folder, optional FDA, baseline, investigation, export, pause/quit, and uninstall scenarios.
- Collect local scorecards only through explicit preview/export.
- Triage every misleading attribution, unexplained residual, permission loop, high-resource condition, or migration error as release-critical until reviewed.
- Publish Known Limitations draft and benchmark methodology.

### Week 7 — Release Candidate Hardening

- Complete at least six formative/moderated KPI-01 sessions; address repeated blockers.
- Run full compatibility, performance, database, redaction, accessibility, and no-network matrix on release candidate.
- Test install and upgrade on a clean macOS user account for each supported major.
- Freeze schema/rule format unless a Sev-0/Sev-1 fix requires change.
- Complete README, installation, privacy, permission, troubleshooting, contribution, rule authoring, security reporting, and removal documentation.

### Week 8 — Public Beta Decision and Launch

- Review every PRD Public Beta release gate with linked evidence.
- Publish artifact checksum, source commit, third-party notices, supported versions, known limitations, benchmark results, and installation/security status.
- Tag the release only after go decision; retain a tested rollback artifact and migration instructions.
- Open a public feedback channel through structured GitHub issues; do not add telemetry for launch measurement.

### Beta Exit Criteria

Beta phase is considered successfully launched when:

- Public Beta release gates in the PRD all pass.
- Release artifact and source are publicly accessible under the approved license.
- At least one verified install/observe/investigate/export cycle succeeds on macOS 15.6 and the current stable macOS on Apple Silicon; public materials explicitly exclude macOS 14 and Intel.
- No open Sev-0/Sev-1 issue is known at launch.
- Known limitations plainly cover System Data mismatch, Full Disk Access blind spots, clones/hard links, placeholders, snapshots/purgeable space, and event gaps.

Public Beta does not imply readiness for 1.0. Post-launch evidence must satisfy the next phase gates.

### Dependencies

- Representative Beta participants and consented usability sessions.
- Release/signing credentials if Developer ID distribution is selected.
- Maintainer capacity for rapid Sev-0/Sev-1 triage during launch week.
- Clean machines/accounts and supported-OS test availability.

## Phase 5 — 1.0 (Date TBD)

### Objective

Promote SpaceTrace to a stable release only after Beta demonstrates understandable attribution, reliable history, sustainable maintenance, and a secure distribution story.

### Entry Criteria

- Public Beta has been available for at least four weeks (**Assumption**) or an approved decision identifies equivalent longitudinal evidence.
- KPI-01 completes at least 12 moderated sessions and meets the 80% task-success target.
- Repeated Beta issues are grouped and P1 scope is selected based on evidence.
- Distribution/update decisions and long-term supported-version policy are approved.

### Candidate 1.0 Scope

- All validated P0 capabilities and Beta fixes.
- Upgrade/migration path from every public Beta schema.
- At most one or two P1 features with demonstrated impact; likely candidates are configurable alerts, custom watch/exclusion rules, or custom baseline markers.
- P1 selection is TBD and must not be inferred from this roadmap.

### 1.0 Exit Criteria

- All PRD 1.0 gates pass.
- KPI-01 through KPI-06 pass with published release-candidate evidence.
- Zero open Sev-0/Sev-1 issues and no repeated unresolved Sev-2 issue affecting credibility, privacy, integrity, or resource use.
- Update, rollback, migration, uninstall, and support policies are tested and documented.
- Stable API/schema/rule compatibility policy is documented for contributors.
- Maintainers agree the support burden is sustainable for at least the next two macOS release cycles.

### Dependencies

- Longitudinal Public Beta observations and opt-in user feedback.
- Maintainer capacity and ownership.
- Developer ID/update-channel resolution.
- Final selection of supported languages and any P1 feature.

## Cross-Phase Workstreams

### Quality and Release Evidence

Each milestone produces an evidence pack containing:

- Version/commit and supported OS/hardware matrix.
- Functional requirement status with links to tests or manual evidence.
- Performance benchmark protocol and results.
- Classifier corpus version and per-category precision.
- Migration, recovery, low-disk, event-gap, and redaction results.
- Accessibility status and known limitations.
- Dependency/license inventory and network/privacy verification.
- Open risks and defect severity summary.

### Documentation-as-Code

- Product, architecture, security, engineering, user, and contributor docs live in the repository.
- Feature and schema changes update documentation in the same pull request.
- Every public release has version-aligned installation, permissions, measurement semantics, troubleshooting, privacy, uninstall, and migration information.
- Commands and code examples are tested on a clean supported environment before publication.

### Privacy and Security

- Threat model starts in Discovery and is updated for new integrations.
- Dynamic no-network test and diagnostic redaction test run for every release candidate.
- New dependencies require license, data-flow, network, and maintenance review.
- Any proposal for telemetry, cloud processing, privileged helper, automatic deletion, or executable community rules stops normal implementation and requires a new product/security decision.

### User Research Without Telemetry

- Discovery interviews and Beta usability tests use explicit consent and minimal notes.
- Local scorecards remain on-device until the user previews and exports them.
- GitHub templates request redacted evidence and warn against publishing private paths.
- Public aggregate reporting contains no individual path, filename, machine ID, or account identity.

## Dependency and Decision Timeline

| Decision/dependency | Owner | Due | Blocking consequence |
|---|---|---|---|
| Confirm audience and top investigation journey | Product owner (TBD) | Discovery exit | No Prototype go decision |
| Qualify the accepted macOS 15.6 Apple Silicon baseline on the minimum-runtime matrix | Engineering + Product owners (TBD) | Public Beta entry | Public compatibility claim and Beta release remain blocked |
| Approve core architecture and persistence choice | Architecture owner (TBD) | Prototype exit | Alpha cannot start |
| Approve size semantics and unknown/coverage language | Product + Engineering (TBD) | Prototype exit | No user-visible attribution |
| Approve MIT license and repository notices | Project owner (TBD) | Before first public source release | No public release |
| Confirm Full Disk Access UX and selected-folder fallback | Product + Security (TBD) | Alpha exit | Beta blocked |
| Select Beta language(s) | Product owner (TBD) | Alpha exit | Localization/documentation freeze blocked |
| Decide Developer ID signing/notarization | Project owner (TBD) | Beta entry | Public Beta blocked or requires explicit unsigned risk acceptance |
| Decide update mechanism | Engineering + Security (TBD) | Beta entry | Manual updates only; must be documented |
| Secure supported-OS real-device matrix | QA owner (TBD) | Week 6 | Public Beta compatibility gate blocked |
| Select 1.0 P1 scope and date | Product owner (TBD) | After Beta evidence | 1.0 remains uncommitted |

## Explicit Non-Commitments

The roadmap does not commit any of the following:

- A 1.0 release date.
- Intel Mac and macOS 14 support. The initial supported baseline is macOS 15.6 or later on Apple Silicon.
- Mac App Store distribution.
- Developer ID signing/notarization until the decision gate, although it is strongly preferred for a public release.
- Automatic update delivery.
- Exact replication of Apple’s System Data value.
- Process-level write attribution.
- Automatic or one-click deletion, cache cleaning, snapshot removal, process termination, or system-database modification.
- Network/NAS monitoring in Beta.
- AI-based classification, cloud accounts, synchronization, telemetry, or automatic diagnostic upload.
- P1/P2 features for Public Beta or 1.0.
- Backup Canary, CloudGuard Dev, or unrelated utility modules.

## Change Control

A roadmap change requires a short decision record when it does any of the following:

- Changes a P0 requirement or acceptance threshold.
- Changes privacy, local-only, read-only, permission, compatibility, or distribution assumptions.
- Adds a privileged helper, private API, network dependency, telemetry, destructive operation, or executable extension.
- Moves Public Beta later than Week 8 or claims a 1.0 date.
- Adds a feature while a phase exit gate is failing.

The decision record must state the evidence, user impact, alternatives, schedule effect, migration/security implications, and rollback. Calendar pressure alone is not sufficient evidence to weaken a safety or credibility gate.
