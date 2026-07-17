# SpaceTrace

SpaceTrace is a local-first macOS utility that explains **where disk space changed over time**. It is designed to answer a narrow, high-value question:

> What caused my Mac to lose disk space during the last day or week?

The repository contains the initial Xcode macOS app scaffold. Product behavior has not been implemented yet; the current work establishes the product, architecture, privacy, and engineering contracts that implementation must follow.

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
| Privacy and threat model | [Privacy and Security](docs/security/privacy-and-security.md) |
| Opportunity research | [Research Notes](docs/research/macos-opportunity-research-2026.md) · [Interactive Report](docs/research/macos-opportunity-research-2026.html) |
| Shared terminology | [Glossary](docs/glossary.md) |
| Documentation map | [Documentation Index](docs/README.md) |

## Project status

- Stage: product discovery and technical design; Xcode scaffold created
- Target: public beta in approximately eight weeks (**assumption; pending confirmation**)
- Supported baseline: macOS 15.6+, Apple Silicon first
- Minimum-version qualification: build/test configuration is aligned; a macOS 15.6 runtime matrix remains required before Public Beta
- Proposed implementation: Swift, SwiftUI with targeted AppKit integration
- Proposed license: MIT (**TBD until explicitly approved**)
- Distribution and signing: Developer ID, notarization, and update strategy remain release-blocking decisions

## Contributing

Contribution rules, review gates, and decision processes are defined in [CONTRIBUTING.md](CONTRIBUTING.md). Before feature implementation begins, changes should focus on validation spikes, fixtures, accepted decisions, and making the scaffold match the approved support baseline.

## Decision hierarchy

When documents disagree, use this order:

1. Accepted Architecture Decision Records
2. Product Requirements and approved change records
3. Technical Architecture
4. Security, Quality, and Development Process documents
5. Roadmap and research artifacts

Open conflicts must be resolved through an ADR or PRD change before implementation.
