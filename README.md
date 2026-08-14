# SpaceTrace

SpaceTrace is a local-first macOS utility that explains **where disk space changed over time**. It is designed to answer a narrow, high-value question:

> What caused my Mac to lose disk space during the last day or week?

The repository contains the Xcode macOS app, tested local Swift modules, and the first user-facing permission, baseline, history, reconciliation, and menu-bar slices. It remains an architecture-stage product rather than a release-qualified app; current work establishes strict evidence contracts for each additional workflow.

## Product principles

- **Explain before acting.** SpaceTrace observes and explains; it does not silently delete files.
- **Local by default.** File paths, usage patterns, and diagnostic data remain on the Mac.
- **Evidence over guesses.** Every attribution must show a path, time window, observed delta, and confidence level.
- **Graceful permission degradation.** Full Disk Access is an optional coverage enhancement, not a hidden requirement.
- **Low overhead is a feature.** The observer must not become a material source of CPU use, battery drain, or disk writes.
- **Public APIs first.** Private macOS APIs must not be required for the MVP.

## Current scope

The proposed MVP records volume capacity, directory summaries, file-system change signals, and relevant snapshot metadata. It classifies high-value growth sources such as Xcode, simulators, Docker or VM images, AI models, app caches and logs, cloud-local files, and APFS or Time Machine snapshots.

The MVP does **not** promise exact process attribution, reproduce Apple's System Data number, provide antivirus scanning, or perform automatic cleanup.

## Documentation

| Area | Document |
|---|---|
| Product source of truth | [Product Requirements](docs/product/product-requirements.md) |
| Delivery plan | [Product Roadmap](docs/product/product-roadmap.md) |
| System design | [Technical Architecture](docs/architecture/technical-architecture.md) |
| Architecture decisions | [ADR Index](docs/architecture/decisions/README.md) |
| Engineering lifecycle | [Development Process](docs/engineering/development-process.md) |
| Verification gates | [Quality Strategy](docs/engineering/quality-strategy.md) |
| Current implementation evidence | [First Implementation Slice Status](docs/engineering/implementation-status.md) |
| Startup-volume history and reconciliation | [Engineering contract](docs/engineering/startup-volume-history-and-reconciliation.md) · [中文](docs/engineering/startup-volume-history-and-reconciliation.zh-CN.md) |
| Background sampling lifecycle and menu bar | [Engineering contract](docs/engineering/background-storage-sampling-lifecycle.md) · [中文](docs/engineering/background-storage-sampling-lifecycle.zh-CN.md) |
| Background 24-hour soak qualification | [Qualification protocol](docs/engineering/background-soak-qualification.md) · [中文](docs/engineering/background-soak-qualification.zh-CN.md) |
| Deterministic storage attribution | [Engineering contract](docs/engineering/deterministic-attribution.md) · [中文](docs/engineering/deterministic-attribution.zh-CN.md) |
| Ad-hoc release candidate packaging | [Checklist](docs/engineering/release-candidate-checklist.md) · [中文](docs/engineering/release-candidate-checklist.zh-CN.md) |
| FSEvents continuity qualification | [Protocol](docs/engineering/fsevents-continuity-qualification.md) · [中文](docs/engineering/fsevents-continuity-qualification.zh-CN.md) |
| Scan scheduling lifecycle | [Engineering contract](docs/engineering/scan-scheduling-lifecycle.md) · [中文](docs/engineering/scan-scheduling-lifecycle.zh-CN.md) |
| Privacy and threat model | [Privacy and Security](docs/security/privacy-and-security.md) |
| Opportunity research | [Research Notes](docs/research/macos-opportunity-research-2026.md) · [Interactive Report](docs/research/macos-opportunity-research-2026.html) |
| Shared terminology | [Glossary](docs/glossary.md) |
| Documentation map | [Documentation Index](docs/README.md) |

## Project status

- Stage: architecture spike with user-facing directory authorization, coverage-aware baseline, and directory/startup-volume history reconciliation flows; not yet beta- or release-qualified
- Target: public beta in approximately eight weeks (**assumption; pending confirmation**)
- Supported baseline: macOS 15.6+, Apple Silicon first
- Minimum-version qualification: build/test configuration is aligned; a macOS 15.6 runtime matrix remains required before Public Beta
- Proposed implementation: Swift, SwiftUI with targeted AppKit integration
- Implemented foundation: local `SpaceTraceKit` modules for domain observations, deterministic path/context attribution with versioned evidence and Unknown fallback, bounded FSEvents and mount lifecycles, security-scoped directory authorization, a metadata-only bounded calibration scanner, revision-safe SQLite publication, multi-root baseline UI, monotonic startup-volume capacity history, conservative storage reconciliation, typed power/thermal/sleep pause-and-retry scheduling, and qualified 24-hour menu-bar evidence
- License: [PolyForm Noncommercial License 1.0.0](LICENSE.md) — source-available; noncommercial use, modification, and distribution are permitted, while commercial use by ordinary recipients is not licensed
- Distribution and signing: fail-closed ad-hoc RC packaging is implemented for trusted testing; Developer ID, notarization, the complete replacement matrix, and update strategy remain release blockers

## Contributing

Contribution rules, the [Contributor License Agreement](CONTRIBUTOR_LICENSE_AGREEMENT.md), review gates, and decision processes are defined in [CONTRIBUTING.md](CONTRIBUTING.md). Contributors retain ownership while granting the repository owner the additional rights needed for future commercial licensing. Run `make verify` before submitting a change. Feature work should continue to prioritize validation spikes, fixtures, accepted decisions, and explicit evidence boundaries.

## Decision hierarchy

When documents disagree, use this order:

1. Accepted Architecture Decision Records
2. Product Requirements and approved change records
3. Technical Architecture
4. Security, Quality, and Development Process documents
5. Roadmap and research artifacts

Open conflicts must be resolved through an ADR or PRD change before implementation.
