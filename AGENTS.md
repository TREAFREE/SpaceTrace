# Agent Instructions for SpaceTrace

## Mission

Build a trustworthy, local-first macOS utility that explains disk-space changes over time. Reliability, privacy, and evidence quality are more important than feature count.

## Source-of-truth order

1. Accepted ADRs in `docs/architecture/decisions/`
2. `docs/product/product-requirements.md`
3. `docs/architecture/technical-architecture.md`
4. `docs/security/privacy-and-security.md`
5. `docs/engineering/quality-strategy.md`
6. `docs/engineering/development-process.md`

If two sources conflict, stop implementation of the affected behavior and propose the smallest PRD change or ADR needed to resolve it.

## Non-negotiable product constraints

- Do not add automatic deletion, force quit, snapshot deletion, or protected-system mutation to the MVP.
- Do not claim exact process attribution from FSEvents.
- Do not claim parity with Apple's System Data classification.
- Do not make a private API, undocumented database, or brittle command output the only implementation path for a P0 requirement.
- Do not upload paths, file names, usage history, or diagnostic data without an explicit user action and a reviewed privacy change.
- Full Disk Access must remain an optional coverage enhancement unless the PRD is explicitly changed.
- Unknown evidence must remain unknown; never manufacture an attribution to improve apparent coverage.

## Engineering expectations

- Write tests or fixtures before implementing parsers, migrations, and attribution rules.
- Put macOS-specific API and command interactions behind versioned source adapters.
- Use deterministic classification rules with an explanation and confidence level.
- Bound scans by time, path count, or work budget; cancellation and sleep/wake behavior are part of correctness.
- Treat schema migrations, FSEvents cursor recovery, and permission loss as first-class test scenarios.
- Never log raw user paths in CI artifacts or public issue templates.

## Change control

- New user-visible behavior requires an existing `FR-*` requirement or a PRD change.
- A durable technology, data model, permission, distribution, or security decision requires an ADR.
- A change that weakens privacy or expands mutation capabilities requires explicit maintainer approval and threat-model review.
- Update affected documentation in the same pull request as code.

## Working style

- Other agents and contributors may be editing the repository. Do not revert unrelated work.
- Keep changes scoped and preserve stable identifiers.
- Prefer English file names and code identifiers. Product documentation may be Chinese until localization policy is accepted.
- Use `rg` for repository searches and non-destructive commands for inspection.
- Do not initialize, commit, push, publish, sign, or notarize without explicit user authorization.

## Verification

Run repository hygiene checks for every change:

```bash
git diff --check
xcodebuild -list -project SpaceTrace.xcodeproj
```

Use the same full verification entry point as CI:

```bash
make verify
```

Run the complete UI-test command from `CONTRIBUTING.md` in an interactive macOS session when UI journeys become meaningful because the UI-test runner must bootstrap a GUI application. Add lint and performance commands here and to `CONTRIBUTING.md` when their pinned tooling lands.
