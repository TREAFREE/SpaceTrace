# SpaceTrace Documentation

This directory is the durable source of truth for product, architecture, engineering, security, and research decisions.

## Reading paths

### Product and design review

1. [Product Requirements](product/product-requirements.md)
2. [Product Roadmap](product/product-roadmap.md)
3. [Technical Architecture](architecture/technical-architecture.md)
4. [Privacy and Security](security/privacy-and-security.md)

### Engineering onboarding

1. [Repository README](../README.md)
2. [Glossary](glossary.md)
3. [Technical Architecture](architecture/technical-architecture.md)
4. [ADR Index](architecture/decisions/README.md)
5. [Development Process](engineering/development-process.md)
6. [Quality Strategy](engineering/quality-strategy.md)
7. [First Implementation Slice Status](engineering/implementation-status.md)
8. [Contributing](../CONTRIBUTING.md)

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
