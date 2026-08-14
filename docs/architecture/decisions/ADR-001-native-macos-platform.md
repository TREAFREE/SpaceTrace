# ADR-001: Native macOS modular monolith and supported-platform baseline

## Status

Accepted — macOS 15.6 is the minimum deployment target; Apple Silicon is the primary supported architecture; Intel support remains deferred.

Date: 2026-07-18

## Context

SpaceTrace is a menu-bar-oriented utility whose differentiating work depends on macOS-specific capabilities: FSEvents, filesystem metadata, APFS volume semantics, power and thermal state, permissions, launch at login, Developer ID distribution, and notarization. It has no backend and is expected to be maintained initially by a small source-available project team.

The initial Xcode scaffold used macOS 26.1. On 2026-07-18, the project owner selected macOS 15.6 as the product floor. The project-level, application, unit-test, and UI-test Debug/Release configurations now declare:

- `MACOSX_DEPLOYMENT_TARGET = 15.6`;
- Swift language version setting `5.0`;
- bundle identifier `com.TREAFREE.SpaceTrace`;
- automatic development signing.

Choosing the deployment target establishes the engineering and product baseline. It does not replace release qualification: the application must still exercise every P0 platform adapter and user journey on macOS 15.6 before Public Beta.

The team also needs module boundaries strong enough to test crash recovery and platform failures without paying the operational cost of multiple processes or services.

## Decision

1. Build SpaceTrace as a native Swift application using SwiftUI for primary presentation and AppKit where menu-bar/window lifecycle or mature macOS controls require it.
2. Use a **single-process modular monolith**. The existing app target becomes a thin composition root; domain, application, filesystem, persistence, attribution, platform, and UI code evolve into targets in one local Swift package.
3. Set **macOS 15.6** as the minimum deployment target for the project, application, unit-test, and UI-test configurations.
4. Make Apple Silicon the primary development, performance, and release-qualification architecture. Do not claim Intel support until an x86_64 build and OS matrix is explicitly accepted. Keep pure Swift modules portable enough that a Universal 2 build remains feasible.
5. Treat macOS 15.6 runtime qualification as a Public Beta gate. A clean build on a newer host proves SDK availability, not runtime compatibility; the validation plan below must pass on a physical or virtual macOS 15.6 environment.
6. Adopt Swift 6 strict-concurrency checking as the target engineering mode after a separate migration spike from the scaffold's current Swift 5.0 setting. This ADR does not assert that migration is complete.
7. Review bundle-identifier ownership and replace development automatic signing with a documented release-signing path before external distribution.

## Options considered

| Option | Benefits | Costs / failure modes | Assessment |
| --- | --- | --- | --- |
| Native Swift/SwiftUI modular monolith | Best access to public macOS APIs; small distribution; native energy behavior; strong test seams without runtime distribution | Requires macOS expertise; SwiftUI may need AppKit escape hatches | Selected |
| Native app with multiple helpers/services from day one | Fault/process isolation; independent helper lifecycle | Signing, FDA, IPC, updates, crash recovery, and debugging become materially harder | Rejected for MVP |
| Electron/Tauri cross-platform shell | Familiar web UI; possible future platform reach | Core problem remains macOS-only; larger footprint; bridge/security/energy cost; no near-term second platform | Rejected |
| macOS 14.x minimum | Broader audience | Larger compatibility matrix and additional availability/behavior branches | Deferred; reconsider only with measured demand |
| macOS 15.6 minimum | Modern public APIs, smaller support matrix, materially broader reach than the initial scaffold | Excludes Sonoma and earlier; still requires oldest-OS qualification infrastructure | Selected |
| macOS 26.1 minimum | Simplest relative to the original scaffold | Excludes intended users and hides compatibility problems | Rejected |
| arm64-only binary | Smallest support and test matrix | Excludes Intel Macs | Selected initial release boundary |
| Universal 2 at launch | Broader audience; low source-level cost for pure Swift | Doubles architecture qualification and may constrain dependencies | Deferred until demand and capacity justify it |

## Consequences

### Positive

- Platform-specific behavior remains behind adapters while the core can be tested deterministically.
- One process keeps permission, update, crash, and state ownership understandable.
- The application can use SwiftUI without forcing unsuitable controls or lifecycle behavior where AppKit is stronger.
- Every target shares one explicit deployment floor, preventing host-app/test-bundle mismatches.
- macOS 15.6 materially broadens the intended audience compared with the original scaffold.

### Negative and accepted trade-offs

- The local package contains several targets, adding build configuration and dependency enforcement.
- Swift 6 concurrency migration may expose isolation defects before feature work proceeds.
- Intel and macOS 14 users are outside the initial support boundary.
- Testing the minimum and current macOS releases requires physical or virtual infrastructure that GitHub-hosted CI may not fully provide.

### Guardrails

- No domain target may import SwiftUI, AppKit, CoreServices, DiskArbitration, GRDB, or process APIs.
- Add architecture tests or a dependency script that rejects target cycles and forbidden imports.
- Do not introduce XPC/helper targets without a superseding ADR and measured need.
- All target and project build configurations must retain the same deployment floor unless a narrower test-only reason is documented.
- APIs introduced after macOS 15.6 require an availability guard, adapter fallback, or a deliberate update to this ADR and the support matrix.
- Documentation and release notes must state macOS 15.6 and Apple Silicon precisely; they must not imply Intel or macOS 14 support.

## Validation plan

Repository-level acceptance evidence:

1. Project, app, unit-test, and UI-test Debug/Release configurations resolve to macOS 15.6.
2. Debug and Release builds complete with the current stable Xcode and signing disabled.
3. The unit-test target builds and runs successfully.

Before Public Beta, qualification must additionally provide:

1. a physical or virtual macOS 15.6 Apple Silicon run of every P0 journey;
2. FSEvents create/start/replay, dropped-event, and calibration smoke tests;
3. volume-capacity, file-allocation, DiskArbitration, low-power/thermal, menu-bar, launch-at-login, SQLite, and FDA-degradation checks;
4. SwiftUI/AppKit first-run, settings, keyboard, and VoiceOver smoke tests;
5. dependency availability and signed/notarized-build validation if that distribution path is approved;
6. an arm64 release-size/startup baseline;
7. a documented CI matrix covering macOS 15.6 qualification and the current stable macOS.

## Revisit triggers

- A P0 requirement is unavailable or unreliable on macOS 15.6.
- Supporting macOS 14 has measured user value that justifies its additional test and compatibility cost.
- Intel demand is material and dependencies build cleanly as Universal 2.
- The single process cannot meet lifecycle/freshness SLOs after measured optimization.
- A second platform becomes an approved product objective.
- SwiftUI/AppKit interoperability introduces a recurring blocker that changes the UI architecture.
