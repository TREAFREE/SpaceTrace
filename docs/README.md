# SpaceTrace Documentation

This directory is the durable source of truth for product, architecture, engineering, security, and research decisions.

## Reading paths

### Product and design review

1. [Product Requirements](product/product-requirements.md)
2. [Product Roadmap](product/product-roadmap.md)
3. [Visual Design System](product/visual-design-system.md) · [中文](product/visual-design-system.zh-CN.md)
4. [Technical Architecture](architecture/technical-architecture.md)
5. [Privacy and Security](security/privacy-and-security.md)

### Engineering onboarding

1. [Repository README](../README.md)
2. [Glossary](glossary.md)
3. [Technical Architecture](architecture/technical-architecture.md)
4. [ADR Index](architecture/decisions/README.md)
5. [Development Process](engineering/development-process.md)
6. [Quality Strategy](engineering/quality-strategy.md)
7. [First Implementation Slice Status](engineering/implementation-status.md)
8. [FSEvents Continuity-Loss Qualification](engineering/fsevents-continuity-qualification.md) · [中文](engineering/fsevents-continuity-qualification.zh-CN.md)
9. [Security-Scoped Bookmark and Application Lifecycle](engineering/security-scoped-bookmark-lifecycle.md) · [中文](engineering/security-scoped-bookmark-lifecycle.zh-CN.md)
10. [User-Selected Directory UI and Sandbox Qualification](engineering/user-selected-directory-qualification.md) · [中文](engineering/user-selected-directory-qualification.zh-CN.md)
11. [Authorized Directory Baseline and Overview](engineering/authorized-baseline-overview.md) · [中文](engineering/authorized-baseline-overview.zh-CN.md)
12. [Scan Scheduling Lifecycle](engineering/scan-scheduling-lifecycle.md) · [中文](engineering/scan-scheduling-lifecycle.zh-CN.md)
13. [SQLite Adapter Evidence Review](engineering/sqlite-adapter-evidence-review.md) · [中文](engineering/sqlite-adapter-evidence-review.zh-CN.md)
14. [SQLite Recovery Lifecycle](engineering/sqlite-recovery-lifecycle.md) · [中文](engineering/sqlite-recovery-lifecycle.zh-CN.md)
15. [SQLite History and Benchmark](engineering/sqlite-history-benchmark.md) · [中文](engineering/sqlite-history-benchmark.zh-CN.md)
16. [SQLite v12 Correction Prototype](engineering/sqlite-v12-correction-benchmark.md) · [中文](engineering/sqlite-v12-correction-benchmark.zh-CN.md)
17. [Directory History Application Layer and Overview](engineering/directory-history-overview.md) · [中文](engineering/directory-history-overview.zh-CN.md)
18. [Startup Volume History and Storage Reconciliation](engineering/startup-volume-history-and-reconciliation.md) · [中文](engineering/startup-volume-history-and-reconciliation.zh-CN.md)
19. [Direct DMG Distribution and Code Signing](engineering/direct-distribution-signing.md) · [中文](engineering/direct-distribution-signing.zh-CN.md)
20. [Ad-hoc Release Candidate Checklist](engineering/release-candidate-checklist.md) · [中文](engineering/release-candidate-checklist.zh-CN.md)
21. [Background Storage Sampling Lifecycle and Menu Bar](engineering/background-storage-sampling-lifecycle.md) · [中文](engineering/background-storage-sampling-lifecycle.zh-CN.md)
22. [Background Soak Qualification](engineering/background-soak-qualification.md) · [中文](engineering/background-soak-qualification.zh-CN.md)
23. [Deterministic Storage Attribution](engineering/deterministic-attribution.md) · [中文](engineering/deterministic-attribution.zh-CN.md)
24. [Immutable, Coverage-Aware Historical Findings](engineering/immutable-historical-findings.md) · [中文](engineering/immutable-historical-findings.zh-CN.md)
25. [Release Integration Audit](engineering/release-integration-audit.md) · [中文](engineering/release-integration-audit.zh-CN.md)
26. [Contributing](../CONTRIBUTING.md)

### Product evidence

- [Research Notes](research/macos-opportunity-research-2026.md)
- [Interactive Research Report](research/macos-opportunity-research-2026.html)
- [Portable Report Artifact](research/macos-opportunity-research-2026.artifact.json)

## Document ownership

| Document class | Purpose | Change control |
|---|---|---|
| PRD | Defines user problem, scope, requirements, and launch gates | Product review; material scope changes require a PRD change record |
| Architecture | Describes the current system design | Architecture review; durable trade-offs require an ADR |
| ADR | Records one significant decision and its consequences | Immutable after acceptance; supersede with a new ADR |
| Engineering policy | Defines delivery and quality gates | Maintainer review |
| Security policy | Defines privacy boundaries and threat controls | Security review for any weakening change |
| Research | Preserves evidence and assumptions | Additive corrections with source links |

## Templates

- [RFC Template](templates/rfc-template.md)
- [ADR Template](templates/adr-template.md)
- [Test Plan Template](templates/test-plan-template.md)

## Documentation rules

- File and directory names use lowercase English kebab-case, except conventional root files such as `README.md` and `CONTRIBUTING.md`.
- Requirement identifiers are stable; do not renumber accepted `FR-*` or `NFR-*` items.
- Assumptions and unresolved questions must be marked `Assumption` or `TBD` with an owner and review trigger.
- User-facing behavior changes require matching PRD acceptance criteria and test coverage.
- Security and privacy claims must describe the actual data path, not only intent.
